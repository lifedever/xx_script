# BoxX 进程管理优化设计

## 背景

BoxX 通过 XPC 特权 Helper 管理 sing-box 进程。当前存在以下问题：
- `deployRuntime()` 被重复调用（ConfigEngine 触发一次，applyConfig 再触发一次）
- SIGHUP 后硬编码 sleep 3s 才探测连通性
- 连通性探测走 HTTP 代理端口，TUN 模式下不可靠
- 启动就绪检查用固定 500ms 间隔轮询，不够高效
- DNS 刷新只清系统缓存，未清 sing-box 内部缓存

## sing-box 源码关键发现

以下结论基于 sing-box 1.13+ 源码验证：

### SIGHUP 行为（cmd/sing-box/cmd_run.go:169-202）

SIGHUP 不是原地热重载，而是**进程内重建**：
1. 收到 SIGHUP → `check()` 校验新配置（读取配置文件，创建 box 实例但不 Start，验证通过后 Close）
2. 校验通过 → `cancel()` + `instance.Close()` 关闭旧实例（TUN 拆除、Clash API 关闭、所有连接断开）
3. `create()` → 重新读取配置 → `instance.Start()` 创建新实例
4. 如果 Close 超过 10 秒（`FatalStopTimeout`），进程 fatal 退出

SIGHUP 比 full restart 快的原因：省去进程 kill/spawn、端口释放等待、XPC 调用开销。

### 启动顺序（box.go:464-492）

```
internalService → Start      (Clash API 加载缓存，不监听端口)
inbound (TUN)   → Start      (TUN 网卡建立)
所有组件         → PostStart
所有组件         → Started
internalService → Started    (Clash API 开始监听 HTTP 端口) ← 最后一步
```

**Clash API 端口监听（`StartStateStarted`）在 TUN 启动之后。** 因此 Clash API 可达 = 所有组件已完成启动，包括 TUN。

### Clash API DNS 刷新端点（experimental/clashapi/cache.go）

| 端点 | 作用 |
|------|------|
| `POST /cache/dns/flush` | 清 sing-box 内部 DNS 缓存（dnsRouter.ClearCache） |
| `POST /cache/fakeip/flush` | 清 FakeIP 映射缓存（cacheFile.FakeIPReset） |

### 关闭连接端点

`DELETE /connections` 关闭所有活跃连接（BoxX 已在使用）。

## 设计

### 1. 职责划分

当前 ConfigEngine 通过 `onDeployComplete` 间接触发进程操作，AppState.applyConfig() 又反过来调用 ConfigEngine.deployRuntime()，形成环形调用。

改为单向依赖：

| 组件 | 职责 | 不做什么 |
|------|------|---------|
| ConfigEngine | 生成 config.json / runtime-config.json | 不触发进程操作 |
| AppState | 协调配置生成与进程操作的时序 | 不直接操作进程 |
| SingBoxProcess | 进程生命周期（start/stop/reload/flushDNS） | 不管配置生成 |

具体改动：
- `onDeployComplete` 回调只设 `pendingReload = true`，不调 `applyConfig()`
- `applyConfig()` 不再调 `deployRuntime()`（由调用方在 apply 前生成）
- 调用方职责：先 `configEngine.deployRuntime()` → 再 `applyConfig()`

### 2. applyConfig 拆分为两条路径

```swift
func applyConfig() async {
    guard isRunning, pendingReload, !isApplyingConfig else { return }
    isApplyingConfig = true
    defer { isApplyingConfig = false }

    // 校验
    guard await validateConfig() else { return }

    if pendingRestart {
        await restartProcess()
    } else {
        await reloadConfig()
    }
    pendingReload = false
    pendingRestart = false
}
```

**reloadConfig() -- SIGHUP 路径（配置/规则/节点变更）：**
1. 发送 SIGHUP（通过 Helper XPC）
2. 轮询 Clash API 就绪（200ms 间隔，最多 15 次 = 3 秒）
3. 就绪后 flushAllDNS
4. 关闭存量连接（`DELETE /connections`）
5. 如果 3 秒内 Clash API 未恢复 → escalate 到 restartProcess()

**restartProcess() -- 完整重启路径（TUN/inbound/端口变更）：**
1. `singBoxProcess.stop()`（Helper 内部：SIGTERM → 等 2s → SIGKILL → waitForCleanup）
2. 不额外 sleep，信赖 Helper 的端口释放检查
3. `singBoxProcess.start(configPath:)`（内含指数退避就绪检查）
4. 就绪后 flushAllDNS

**路径选择：**
- 默认走 `reloadConfig()`
- 新增 `pendingRestart: Bool` 标记
- 以下场景设 `pendingRestart = true`：
  - TUN 模式开关切换（SettingsView / MenuBarController 的 setTUN）
  - 代理端口变更（SettingsView 的 proxyInbound 修改）
  - 协议栈变更（SettingsView 的 tunStack 修改）
  - IPv6 开关切换（影响 TUN 地址段）
  - TUN 排除地址变更
- 以下场景走 `reloadConfig()`（默认）：
  - 规则变更（添加/删除/启用/禁用 rule-set）
  - 订阅更新（节点列表变化）
  - 策略组变更
  - DNS 设置变更
  - 日志级别变更

### 3. 连通性探测

去掉 `probeConnectivity()`（HTTP 代理端口 + generate_204），改为 Clash API 可达性检查。

依据：sing-box 源码中 Clash API 端口监听是 `StartStateStarted` 阶段的最后一步，在 TUN 启动之后。Clash API 可达即代表所有组件就绪。

不再做外部连通性探测，因为外部不通可能是节点问题，不应触发 full restart。

### 4. DNS 三层刷新

新增 `flushAllDNS()` 方法，替代当前的双重 flushDNS + sleep：

```swift
func flushAllDNS() async {
    // 1. sing-box 内部 DNS 缓存
    try? await api.post("/cache/dns/flush")
    // 2. sing-box FakeIP 缓存
    try? await api.post("/cache/fakeip/flush")
    // 3. 系统 DNS 缓存（通过 Helper 以 root 执行）
    singBoxProcess.flushDNS()
}
```

三步可并行执行。去掉启动/重启流程中的 sleep + 双重 flush。

### 5. 启动就绪检查

替换当前的 `DispatchQueue.global` + `Thread.sleep(0.5)` + `DispatchSemaphore` 模式。

改为 async/await + 指数退避：

```swift
func waitForReady(timeout: TimeInterval = 60) async -> Bool {
    let start = Date()
    var interval: TimeInterval = 0.2
    while Date().timeIntervalSince(start) < timeout {
        if checkClashAPISync() { return true }
        try? await Task.sleep(for: .seconds(interval))
        interval = min(interval * 2, 1.0)  // 200ms → 400ms → 800ms → 1s
    }
    return false
}
```

正常重启 1-2 秒就绪，首次下载 rule-set 仍保留 60 秒上限。

## 涉及修改的文件

| 文件 | 改动 |
|------|------|
| `AppState.swift` | applyConfig 拆分为 reloadConfig/restartProcess，onDeployComplete 简化，新增 pendingRestart，新增 flushAllDNS，删除 probeConnectivity |
| `SingBoxProcess.swift` | start() 改用 async waitForReady，去掉启动后双重 flushDNS + sleep |
| `ConfigEngine.swift` | deployRuntime 的 onDeployComplete 只设标记不触发 apply |
| `ClashAPI.swift` | 新增 flushDNSCache() / flushFakeIPCache() 方法 |
| `SettingsView.swift` | TUN 开关、端口变更时设 pendingRestart = true |
| `MenuBarController.swift` | 调用方适配新的 apply 流程 |

## 预期效果

| 场景 | 改前耗时 | 改后耗时 |
|------|---------|---------|
| 规则/节点变更（reload） | 5-8 秒 | 1-2 秒 |
| TUN/端口变更（restart） | 8-12 秒 | 3-5 秒 |
| 首次启动（下载 rule-set） | 最多 60 秒 | 不变 |

# BoxX v2 设计文档

## 概述

BoxX v2 是 sing-box 的 macOS 原生客户端（SwiftUI），参考 Surge 的交互设计进行重新设计。采用**核心重写 + 视图层复用**的策略：重写 Services/Models 层，视图层在 v1 基础上改造。

### 核心变化（vs v1）

| 维度 | v1 | v2 |
|------|----|----|
| 配置生成 | Python (generate.py) | Swift 原生 |
| 配置位置 | ~/...singbox/ | /Library/Application Support/BoxX/ |
| 配置管理 | 全量重生成 | 直接读写 config.json，支持手动编辑 + 热重载 |
| 权限管理 | osascript sudo（每次弹密码） | SMAppService + XPC（一次授权） |
| 订阅解析 | Python (generate.py) | Swift 原生 |
| UI 风格 | 基础 SwiftUI | 参考 Surge 交互设计 |

### 环境

- macOS 14.0+, Swift 6.0, SwiftUI
- sing-box at /opt/homebrew/bin/sing-box
- xcodegen at /opt/homebrew/bin/xcodegen
- Clash API: 127.0.0.1:9091, Proxy: 127.0.0.1:7890

---

## 1. 架构

```
┌─────────────────────────────────────────────────┐
│                   BoxX v2 App                    │
├──────────┬──────────┬──────────┬────────────────┤
│  Views   │  Models  │ Services │   SwiftData    │
│ (v1改造) │(Codable) │ (重写)   │ (App层数据)    │
├──────────┴──────────┴──────────┴────────────────┤
│              ConfigEngine (核心)                  │
│  读/写/监听 config.json ← 单一数据源             │
├─────────────────────┬───────────────────────────┤
│    XPC Protocol     │     Clash API Client      │
├─────────────────────┤     (v1 actor 复用)       │
│   BoxXHelper        │                           │
│  (SMAppService)     │                           │
└─────────────────────┴───────────────────────────┘
         ↓                        ↑
   sing-box 进程              127.0.0.1:9091
   /Library/Application Support/BoxX/config.json
```

### 四层分离

| 层 | 职责 |
|---|---|
| **Views** | UI 展示与交互，v1 视图层改造，参考 Surge 交互 |
| **ConfigEngine** | config.json 读写引擎，Codable 映射 + FSEvents 监听 |
| **Services** | 业务逻辑：订阅解析、规则集下载、节点测速等 |
| **Helper (XPC)** | 特权操作：SMAppService 注册，管理 sing-box 进程 |

### 数据流

1. **App 操作** → ConfigEngine 修改内存模型 → 写 config.json → XPC 通知 Helper reload
2. **手动编辑 config.json** → FSEvents 触发 → ConfigEngine 重新加载 → Views 刷新
3. **Helper** 通过 XPC 汇报 sing-box 状态 → AppState 更新 → Views 响应

### 数据存储

- `/Library/Application Support/BoxX/config.json` — sing-box 配置（root + user 均可读写）
- `/Library/Application Support/BoxX/rules/` — 下载的规则集文件
- SwiftData (App sandbox) — 订阅 URL 列表、UI 偏好、上次更新时间等

### SwiftData 模型

```swift
@Model
class Subscription {
    var name: String
    var url: String
    var lastUpdated: Date?
    var nodeCount: Int
}

@Model
class UserRuleSetConfig {
    var ruleSetId: String       // 内置或远程规则集 ID
    var enabled: Bool
    var outbound: String
    var order: Int
}

@Model
class AppPreference {
    var launchAtLogin: Bool
    var scriptDirectory: String?
}
```

**从 v1 迁移：** v1 的 `subscriptions.json` 在首次启动时自动导入到 SwiftData，导入后不再依赖 JSON 文件。

---

## 2. ConfigEngine

config.json 的 Swift 映射引擎，是 v2 最核心的新模块。

### Codable 模型

```swift
struct SingBoxConfig: Codable {
    var log: LogConfig?
    var dns: DNSConfig?
    var inbounds: [Inbound]
    var outbounds: [Outbound]
    var route: RouteConfig
    var experimental: Experimental?
}

enum Outbound: Codable {
    case direct(DirectOutbound)
    case selector(SelectorOutbound)
    case urltest(URLTestOutbound)
    case vmess(VMessOutbound)
    case shadowsocks(SSOutbound)
    case trojan(TrojanOutbound)
    case hysteria2(Hysteria2Outbound)
    case vless(VLESSOutbound)
    // 通过 type 字段区分
}

struct RouteRule: Codable {
    var action: String
    var outbound: String?
    var ruleSet: [String]?
    var domain: [String]?
    var domainSuffix: [String]?
    var ipCidr: [String]?
    var processName: [String]?
}
```

### ConfigEngine API

```swift
@Observable
class ConfigEngine {
    private(set) var config: SingBoxConfig

    func load()                       // 从 config.json 加载
    func save()                       // 写回 config.json
    func startWatching()              // FSEvents 监听外部修改
    func stopWatching()

    // 便捷操作（修改内存模型 + 自动 save）
    func selectProxy(group:, name:)
    func addRule(...)
    func removeRule(at:)
    func reorderRules(from:, to:)
    func addOutbound(...)
    func removeOutbound(...)
}
```

### 设计决策

1. **未知字段保留** — 每个 Codable 结构体在 `init(from:)` 中使用 `KeyedDecodingContainer` 遍历所有 key，已知 key 正常解码，未知 key 收集到 `var unknownFields: [String: JSONValue]` 字典。`encode(to:)` 时先编码已知字段，再写回 unknownFields。`JSONValue` 是自定义递归枚举（string/number/bool/null/array/object），不依赖第三方库。这确保用户手动添加的任何字段在 App 读写后原样保留。
2. **Outbound 未知类型** — Outbound 枚举增加 `.unknown(tag: String, type: String, raw: JSONValue)` case，当 config.json 中出现 App 不认识的 outbound 类型时，原样保留不丢失。
3. **写入策略** — 修改后整体序列化写回（`.prettyPrinted + .sortedKeys`），不做 JSON patch
4. **防抖** — FSEvents 触发后 500ms 防抖再 reload
5. **冲突处理** — 外部编辑始终优先（last write wins）。App 写入前检查 mtime，若文件已被外部修改，则先 reload 外部版本，再在其基础上重新应用 App 的待保存变更。若无法自动合并，弹 toast 提示用户"配置文件已被外部修改，已重新加载"。

---

## 3. Privileged Helper (XPC)

### 架构

```
BoxX.app (用户态)
    ↓ XPC Connection
BoxXHelper (LaunchDaemon, root)
    ↓ Process.run()
sing-box (root 进程)
    ↓ 读取
/Library/Application Support/BoxX/config.json
```

### 从 v1 Helper 演进

v2 基于 v1 的 `BoxXHelper/main.swift` 和 `Shared/HelperProtocol.swift` 演进，不从零重写。

**v1 已有功能（保留）：**
- code signature 验证（SecCode）
- sing-box 进程管理（start/stop/getStatus）
- 端口清理（7890, 9091）
- 孤儿进程检测（pgrep）

**v2 新增方法：**
- `reload` — SIGHUP 热重载
- `flushDNS` — root 权限执行 DNS 缓存清理
- `setSystemProxy` / `clearSystemProxy` — 系统代理设置

**v2 必须修改：**
- 路径验证：v1 硬编码了 `configPath.contains("/singbox/")` 和 `hasPrefix("/tmp/boxx/")`，需改为验证 `/Library/Application Support/BoxX/` 路径
- Mach service name：保持 `com.boxx.helper`

### SMAppService 注册

1. App 首次启动 → `SMAppService.daemon(plistName: "com.boxx.helper")` 注册
2. 系统弹窗请求用户授权（仅一次）
3. Helper 作为 LaunchDaemon 安装，开机自启

**Bundle 结构要求：**
- Helper 二进制：`BoxX.app/Contents/Library/LaunchDaemons/com.boxx.helper`（v1 post-build 脚本已处理）
- LaunchDaemon plist：`BoxX.app/Contents/Library/LaunchDaemons/com.boxx.helper.plist`
- Mach service name 必须在三处一致：plist 的 `MachServices`、Helper 的 `NSXPCListener`、App 的 `NSXPCConnection`
- Helper 需要独立的 code signing identity

**版本升级：** App 更新后调用 `SMAppService.daemon(plistName:).register()` 会自动替换已安装的 Helper 版本。

**实现风险：** SMAppService 对签名和 plist 配置要求严格。建议作为第一个实现任务，独立 spike 验证可行性后再推进其他模块。

### XPC Protocol

在 v1 `HelperProtocol` 基础上扩展：

```swift
@objc protocol HelperProtocol {
    // v1 已有
    func startSingBox(configPath: String, withReply reply: @escaping (Bool, String?) -> Void)
    func stopSingBox(withReply reply: @escaping (Bool, String?) -> Void)
    func getStatus(withReply reply: @escaping (Bool, Int32) -> Void)

    // v2 新增
    func reloadSingBox(withReply reply: @escaping (Bool, String?) -> Void)
    func flushDNS(withReply reply: @escaping (Bool) -> Void)
    func setSystemProxy(port: Int32, withReply reply: @escaping (Bool) -> Void)
    func clearSystemProxy(withReply reply: @escaping (Bool) -> Void)
}
```

### 安全

- Helper 验证调用者 code signature（必须是 com.boxx.app，v1 已实现）
- Hardened Runtime + 公证签名
- XPC 连接中断自动重连

---

## 4. 订阅解析引擎（Swift 原生）

替代 generate.py 的核心模块。

### 解析流程

```
订阅 URL → 下载 → 检测格式 → 解析节点 → 自动分组 → 写入 config.json
```

### 模块拆分

```swift
// 1. 订阅下载
struct SubscriptionFetcher {
    func fetch(url: URL) async throws -> Data
}

// 2. 格式解析（策略模式）
protocol ProxyParser {
    func canParse(_ data: Data) -> Bool
    func parse(_ data: Data) throws -> [ParsedProxy]
}
struct ClashYAMLParser: ProxyParser { ... }
struct SingBoxJSONParser: ProxyParser { ... }

// 3. 解析后的节点模型（注意：与 v1 的 ProxyNode 是不同类型）
struct ParsedProxy {
    let tag: String
    let type: ProxyType           // vmess/ss/trojan/hysteria2/vless
    let server: String
    let port: Int
    let rawConfig: [String: JSONValue]  // 协议特定参数
}

// 4. 自动分组
struct AutoGrouper {
    func group(_ nodes: [ProxyNode]) -> [ProxyGroup]
    // 按节点名关键词匹配地区：香港/HK → 🇭🇰 香港
    // 按订阅源分组：📦订阅名
}
```

### 支持范围

- **格式**：Clash YAML + sing-box JSON
- **协议**：VMess、Shadowsocks、Trojan、Hysteria2、VLESS

### 增量合并

更新订阅时只替换该订阅源的节点，用户手动添加的节点和策略组不受影响。通过节点 tag 前缀（`订阅名-节点名`）区分来源。

### 分组策略

**自动分组 + 手动微调**：App 自动按地区/订阅分组，用户可在此基础上新建、编辑、删除策略组，调整组内节点。

---

## 5. 规则管理系统

### 规则层级

```
路由规则 (route.rules)
├── 单条规则 — 用户手动添加
├── 内置规则集 — App 预置，可启用/禁用
│   ├── AI (openai, anthropic, claude...)
│   ├── Google / YouTube / Netflix / Disney+ / TikTok
│   ├── Microsoft (github, azure...)
│   └── Apple
└── 远程规则集 — 用户添加 URL，自动下载缓存更新
```

### 数据模型

```swift
// 内置规则集（App 内置，随版本更新）
struct BuiltinRuleSet {
    let id: String
    let name: String
    let description: String
    let rules: [RouteRule]
    let defaultOutbound: String
}

// 用户规则集配置（SwiftData）
struct UserRuleSetConfig {
    let ruleSetId: String
    var enabled: Bool
    var outbound: String
    var order: Int
}
```

### Surge 式交互

- 表格展示：类型、匹配内容、策略组、启用开关
- 拖拽排序：规则优先级由上到下
- 命中计数：通过 Clash API 连接数据统计
- 快速添加：从请求列表右键 → "添加规则"
- 规则集管理：独立 Tab，内置一键启用/禁用，远程可添加 URL + 更新间隔

### 规则写入 config.json

- **单条规则** → 直接写入 `route.rules[]` 数组
- **内置规则集** → 打包为本地 rule_set JSON 文件存放在 `/Library/Application Support/BoxX/rules/`，通过 `route.rule_set[]` 引用（不展开为 inline rules，避免 config.json 膨胀）
- **远程规则集** → `route.rule_set[]` 配置远程 URL + 更新间隔 + `rules[]` 中引用

---

## 6. UI 设计

### 主窗口

Surge 经典布局：左侧窄 Sidebar（图标+文字）+ 右侧内容区。

**Sidebar 导航项：**
- 概览 — 状态卡片 + 统计网格 + 模式切换
- 策略组 — 卡片式管理
- 规则 — 表格式管理
- 请求 — 实时连接查看器
- 日志 — 实时日志流
- 订阅 — 订阅管理
- 设置 — App 设置（开机启动、打开配置目录等）

### 策略组页面

- 卡片式两列网格布局
- 按"服务分流 / 地区节点 / 订阅分组"三段分组，带分组标题
- 每张卡片：组名、策略类型标签（select/url-test/fallback）、当前节点 + 延迟指示灯、节点总数
- 点击卡片展开节点列表，可切换选中节点
- 右键编辑策略组（改名、改类型、增删节点）
- 延迟指示灯：绿(<150ms) / 黄(150-300ms) / 红(>300ms)

### 请求查看器

**表格 8 列：** 时间 | 主机 | 协议 | 规则 | 出站 | 链路 | ↓ | ↑

- 默认按时间降序（最新在上）
- 协议颜色区分（TCP 蓝 / UDP 黄）
- 出站列带延迟指示灯，DIRECT 加粗
- 链路列显示完整代理链（服务组 → Proxy → 节点）+ 服务 emoji
- WebSocket 实时推送新连接

**右侧详情面板（点击行展开）：**
- 时间、主机、目标 IP、协议
- 规则匹配路径 — 逐条展示匹配过程（sniff → dns hijack → 命中规则）
- 所属规则集
- 出站链路 — 树形展示代理链 + 协议类型
- 流量（↓/↑）、持续时间
- 快捷操作：添加规则 / 断开连接

**工具栏：** 搜索（域名/进程/规则）、暂停、清空、断开全部

### 菜单栏

Surge 风格平铺 + v1 分组标题：

```
📦 BoxX                    ● 运行中
───────────────────────────────────
出站模式                      规则 ▸
───────────────────────────────────
Proxy                      自动选择 ▸
───────────────────────────────────
服务分流
🤖 OpenAI                  日本 01 ▸
🔍 Google                  香港 03 ▸
📺 YouTube                 自动选择 ▸
...
───────────────────────────────────
地区节点
🇭🇰 香港                    香港 03 ▸
🇯🇵 日本                    日本 01 ▸
...
───────────────────────────────────
订阅分组
📦 SoCloud                 香港 03 ▸
📦 良心云                   日本 01 ▸
───────────────────────────────────
更新订阅
打开配置目录
显示主窗口
退出 BoxX
```

- 三段分组标题（服务分流 / 地区节点 / 订阅分组）
- 每行右侧显示当前选中节点名 + ▸ 箭头
- 点击组展开子菜单选节点
- 底部：更新订阅、打开配置目录、显示主窗口、退出

---

## 7. 错误处理

| 场景 | 处理方式 |
|------|----------|
| sing-box 未安装 | 引导页提示 `brew install sing-box` |
| config.json 格式错误 | 显示错误行号+原因，提供"打开配置目录"按钮，不覆盖文件 |
| Helper 未注册/授权失败 | 引导步骤 + "重新授权"按钮 |
| 订阅 URL 无法访问 | 显示具体错误，不影响其他订阅 |
| 休眠唤醒恢复 | 复用 v1 WakeObserver：flush DNS + close connections + 状态检查 |

---

## 8. ConfigEngine 与 Clash API 的协调

两个数据源各有职责：

| 数据源 | 职责 | 数据 |
|--------|------|------|
| **ConfigEngine** | 持久配置 | 策略组定义、规则列表、outbound 配置 |
| **Clash API** | 运行时状态 | 当前选中节点、延迟测速、活跃连接、实时日志 |

**协调规则：**
- **读取**：UI 展示优先使用 Clash API（反映实时状态），ConfigEngine 提供配置结构
- **写入**：用户切换节点时，同时调用 Clash API（立即生效）和 ConfigEngine.save()（持久化）
- **启动**：App 启动时 ConfigEngine 加载 config.json 获取配置结构，Clash API 获取运行时状态

---

## 9. 测试策略

| 模块 | 测试重点 |
|------|----------|
| ConfigEngine | config.json 读写 round-trip：读入 → 修改 → 写出 → 重新读入，验证未知字段保留 |
| 订阅解析器 | 用真实订阅数据测试 Clash YAML 和 sing-box JSON 格式解析 |
| AutoGrouper | 地区关键词匹配正确性 |
| XPC Protocol | Mock Helper 测试 App 端的 XPC 调用逻辑 |

**首要测试：** ConfigEngine round-trip 测试应在开发第一天编写，使用真实的 sing-box config.json 验证，防止 Codable 序列化丢字段。

---

## 10. v1 复用清单

| 模块 | 复用方式 |
|------|----------|
| ClashAPI.swift (actor) | 直接复用，API 不变 |
| ClashWebSocket.swift | 直接复用 |
| WakeObserver.swift | 改造：保留休眠/唤醒监听逻辑，restart/flushDNS 改为通过 XPC 调用 |
| RingBuffer.swift | 直接复用 |
| ProxyModels / ConnectionModels / LogEntry | 直接复用（ProxyNode 仅用于 Clash API 响应，与新增的 ParsedProxy 不冲突）|
| AppState.swift | 改造：扩展支持 ConfigEngine 状态、规则管理状态等 |
| MainView.swift (Sidebar) | 改造：调整 Tab 项 |
| OverviewView.swift | 改造：调整卡片布局 |
| ProxiesView.swift | 改造：卡片式重设计 |
| ConnectionsView.swift | 改造：8 列 + 详情面板 |
| MenuBarView.swift | 改造：Surge 风格 + 分组标题 |
| LogsView.swift | 基本复用 |
| RulesView.swift | 重写：Surge 式表格管理 |
| SubscriptionsView.swift | 改造：适配新的 Swift 原生解析 |
| SettingsView.swift | 改造：增加"打开配置目录" |
| SingBoxManager.swift | 重写：XPC 替代 osascript |
| ConfigGenerator.swift | 删除：被 ConfigEngine 替代 |
| SubscriptionManager.swift | 重写：SwiftData 替代 JSON 文件 |
| generate.py | 删除：功能迁移到 Swift |
| box.sh | 保留：开发调试用，App 不再依赖 |

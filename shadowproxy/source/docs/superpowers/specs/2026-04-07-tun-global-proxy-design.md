# ShadowProxy TUN 全局代理设计

## 概述

为 ShadowProxy 添加 TUN 全局代理模式，通过 utun 设备 + lwIP 用户态 TCP 栈 + Fake IP 捕获并代理本机所有 TCP 流量。不需要 Apple 开发者账号。

## 设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| TCP 栈 | lwIP（C 库） | 非 Go 生态标准选择，Leaf 同方案 |
| 权限模型 | SMAppService + XPC Helper | macOS 官方特权提升方案 |
| UI 交互 | 系统代理 / 全局代理两个互斥开关 | 直观，互不干扰 |
| DNS 策略 | Fake IP（198.18.0.0/15） | 主流方案，省 DNS 往返，延迟最低 |
| 协议范围 | 仅 TCP（UDP 后续迭代） | 覆盖 95% 场景，复杂度减半 |
| 架构 | Helper 只做特权操作，流量在 App 处理 | Helper 极简，好调试，崩溃不影响流量 |

## 架构

### 组件

```
ShadowProxy.app (用户进程)
├── TUNManager        — 持有 utun fd，读写 IP 包
├── LwIPStack         — lwIP C 桥接，IP 包 → TCP 流重组
├── FakeIPPool        — 域名 ↔ 198.18.x.x 双向映射
├── FakeDNSServer     — UDP 53 监听，返回 Fake IP
├── ProxyEngine       — 现有，规则匹配 + 代理转发（复用）
└── XPC 客户端        — 与 Helper 通信

ShadowProxyHelper (root LaunchDaemon)
├── XPC 服务端
└── 三个操作：
    1. 创建 utun 设备，返回 fd 给 App
    2. 设置路由表（default → utun，排除代理服务器 IP）
    3. 清理恢复（删路由、关 utun）
```

### 数据流

1. App DNS 查询 → 系统 DNS 被路由到本地 FakeDNSServer
2. FakeDNSServer 分配 198.18.x.x，记录映射 → 返回给 App
3. App 连接 198.18.x.x:port → 路由表导向 utun
4. TUNManager 从 utun fd 读取 IP 包 → 喂给 lwIP
5. lwIP 重组 TCP 连接 → 回调 (dstIP, dstPort, data)
6. FakeIPPool 反查 198.18.x.x → 真实域名
7. Router.match(域名) → 策略 → Outbound.relay()（复用现有逻辑）
8. Outbound 响应 → lwIP → IP 包 → utun fd → App 收到数据

### 避免流量死循环

代理服务器的真实 IP 必须绕过 utun，否则代理出站流量会被再次捕获。

方案：设置路由时，为每个代理服务器 IP 添加直连路由：
```
route add <proxy-server-ip>/32 <原默认网关>
```

同时 FakeDNSServer 排除代理服务器域名，不返回 Fake IP。

## 新增模块详细设计

### 1. ShadowProxyHelper（XPC 特权 Helper）

**独立 target**，编译为 `/Library/PrivilegedHelperTools/com.shadowproxy.helper`

XPC 协议：
```swift
@objc protocol HelperProtocol {
    func createTUN(reply: @escaping (Int32, String?) -> Void)
    // 成功返回 utun fd (Int32)，失败返回 -1 + 错误信息

    func setupRoutes(gateway: String, tunName: String,
                     excludeIPs: [String],
                     reply: @escaping (Bool, String?) -> Void)
    // gateway: 原默认网关
    // excludeIPs: 代理服务器 IP，走直连

    func cleanup(tunName: String,
                 reply: @escaping (Bool, String?) -> Void)
    // 恢复路由表，关闭 utun
}
```

Helper 实现：
- 创建 utun：`socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)` + `ioctl` 绑定 `utun`
- 通过 XPC 的 `xpc_connection_send_message_with_reply` 传回文件描述符
- 设置路由：`/sbin/route add/delete` 命令
- DNS 路由：`/sbin/route add 198.18.0.0/15 -interface <utun>` 确保 Fake IP 走 utun

安装方式：
- `SMAppService.loginItem` 已用于开机自启
- Helper 用 `SMAppService` 或 `AuthorizationCopyRights` + `SMJobBless` 注册为 LaunchDaemon
- 首次启用时弹系统密码框，一次授权

### 2. TUNManager

```swift
class TUNManager {
    private var tunFD: Int32 = -1
    private var tunName: String = ""
    private let readQueue = DispatchQueue(label: "tun.read")

    func start(fd: Int32, name: String)
    // 启动后在 readQueue 循环读取 utun fd
    // 每读到一个 IP 包 → 喂给 LwIPStack.input()

    func write(_ packet: Data)
    // lwIP 输出的 IP 包写回 utun fd

    func stop()
}
```

读取方式：`read(tunFD, buffer, MTU)` 循环，MTU = 1500。
macOS utun 包前有 4 字节协议头（AF_INET = 2），需要跳过。

### 3. LwIPStack（Swift-C 桥接）

将 lwIP 源码（`src/core/`, `src/api/`）以 C target 形式加入 SPM。

关键桥接：
```swift
class LwIPStack {
    func initialize(mtu: UInt16)
    // 初始化 lwIP，创建 netif，设置回调

    func input(_ packet: Data)
    // 收到 IP 包，调用 lwIP 的 ip_input()

    var onTCPConnect: ((String, UInt16) -> Void)?
    // lwIP 建立新 TCP 连接时回调，传递 dst IP + port

    var onTCPData: ((UInt32, Data) -> Void)?
    // TCP 连接收到数据时回调，传递连接 ID + 数据

    var onTCPClose: ((UInt32) -> Void)?
    // TCP 连接关闭时回调

    func tcpWrite(connectionID: UInt32, data: Data)
    // 向 TCP 连接写入响应数据

    var onOutput: ((Data) -> Void)?
    // lwIP 需要发出 IP 包时回调 → TUNManager.write()
}
```

lwIP 配置（`lwipopts.h`）：
- `NO_SYS = 1`（无操作系统集成，裸跑）
- `LWIP_TCP = 1`
- `LWIP_UDP = 0`（暂不支持 UDP）
- `MEM_SIZE = 524288`（512KB 内存池）
- `TCP_MSS = 1460`
- `TCP_WND = 65535`（64KB 窗口）
- `LWIP_CALLBACK_API = 1`

### 4. FakeIPPool

```swift
class FakeIPPool {
    private var domainToIP: [String: String] = [:]
    private var ipToDomain: [String: String] = [:]
    private var nextIP: UInt32 = 0xC6120001  // 198.18.0.1 起始

    func allocate(domain: String) -> String
    // 分配一个 198.18.x.x，记录双向映射
    // 池满时 LRU 淘汰

    func lookup(ip: String) -> String?
    // 反查 IP → 域名

    func contains(ip: String) -> Bool
    // 判断是否为 Fake IP 段

    let subnet = "198.18.0.0/15"  // 198.18.0.0 ~ 198.19.255.255，约 13 万地址
}
```

### 5. FakeDNSServer

```swift
class FakeDNSServer {
    private let pool: FakeIPPool
    private let listenPort: UInt16 = 53  // 或 5353 避免冲突

    func start()
    // NWListener UDP 监听
    // 收到 DNS 查询 → 解析域名 → pool.allocate() → 构造 DNS 响应返回

    func stop()
}
```

DNS 查询只处理 A 记录（IPv4）。AAAA 返回空（暂不支持 IPv6）。

如何让系统 DNS 走 FakeDNSServer：
- Helper 设置路由时把 DNS 指向 127.0.0.1
- 或通过 `networksetup -setdnsservers` 指定 127.0.0.1

### 6. UI 变更

Popover 开关区域：
```
┌─────────────────────────┐
│ [●] 系统代理    [○] 全局代理 │  ← 互斥开关
│                         │
│ 节点: xxx               │
│ ...                     │
└─────────────────────────┘
```

点击"全局代理"：
1. XPC 连接 Helper
2. Helper 创建 utun → 返回 fd
3. TUNManager.start(fd)
4. LwIPStack.initialize()
5. FakeDNSServer.start()
6. Helper.setupRoutes()
7. 关闭系统代理（如果开着）

点击关闭"全局代理"：
1. Helper.cleanup()
2. FakeDNSServer.stop()
3. LwIPStack.shutdown()
4. TUNManager.stop()

## 新增文件清单

```
Sources/
├── ShadowProxyCore/
│   ├── TUN/
│   │   ├── TUNManager.swift        — utun fd 读写
│   │   ├── LwIPStack.swift         — lwIP Swift 桥接
│   │   ├── FakeIPPool.swift        — Fake IP 地址池
│   │   └── FakeDNSServer.swift     — Fake DNS 服务器
│   └── System/
│       └── XPCClient.swift         — XPC 客户端
├── ShadowProxyHelper/
│   ├── main.swift                  — Helper 入口
│   ├── HelperProtocol.swift        — XPC 协议定义
│   └── HelperDelegate.swift        — XPC 服务端实现
└── CLwIP/                          — lwIP C 源码 SPM target
    ├── include/
    │   ├── lwipopts.h
    │   └── lwip/ (lwIP headers)
    └── src/
        ├── core/                   — TCP/IP 核心
        └── netif/                  — 网络接口
```

## 不改动的部分

以下现有模块**完全复用**，不做修改：
- ProxyEngine（handleRequest 入口不变）
- Router（规则匹配不变）
- Outbound + Relay（代理转发不变）
- 所有协议实现（SS/VMess/VLESS/Trojan）
- 配置解析、订阅管理

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| lwIP SPM 集成复杂 | 只引入 core + netif 最小子集，自定义 lwipopts.h |
| utun fd 跨进程传递 | macOS XPC 原生支持 fd 传递（`xpc_fd_create`） |
| 崩溃导致断网（路由表残留） | Helper cleanup + App 崩溃信号处理 + launchd KeepAlive 自动恢复 |
| DNS 端口 53 被 mDNSResponder 占用 | 用 5353 端口 + 路由重定向，或直接改系统 DNS 设置 |
| Fake IP 池耗尽 | 198.18.0.0/15 有 ~131K 地址，LRU 淘汰 |

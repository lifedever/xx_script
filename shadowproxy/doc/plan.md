# ShadowProxy Phase 1 实现计划

> **Goal:** CLI 可用的原生 macOS 代理工具，`sp start` 后系统代理模式运行，Claude Code 聊天无延迟不断连。

**Tech Stack:** Swift 6.0, Network.framework, CryptoKit, CommonCrypto, SPM

**项目路径:** `shadowproxy/source/`

---

## Task 1: 配置解析器（ConfigParser）

**文件:**
- `Sources/ShadowProxyCore/Config/ConfigParser.swift`
- `Tests/ShadowProxyCoreTests/ConfigParserTests.swift`

**目标:** 解析 Shadowrocket `.conf` 格式，输出结构化配置。

**解析的 Section:**
- `[General]` → `GeneralConfig`（skip-proxy, dns-server, loglevel）
- `[Proxy]` → `[String: ServerConfig]`（节点列表，支持 ss 和 vmess 格式）
- `[Proxy Group]` → `[ProxyGroup]`（select / url-test）
- `[Rule]` → `[Rule]`（DOMAIN-SUFFIX, DOMAIN, IP-CIDR, GEOIP, RULE-SET, FINAL）

**注意：** Shadowrocket 的 .conf 里没有 `[Proxy]` section（节点来自订阅）。ShadowProxy 需要扩展支持 `[Proxy]` section 来定义节点，格式兼容 Surge：
```
name = ss, server, port, encrypt-method=xxx, password=xxx, obfs=http, obfs-host=xxx
name = vmess, server, port, username=uuid, alterId=0
```

Phase 1 手动在 config.conf 里写节点，后续 Phase 2 再做订阅导入。

**关键类型:**

```swift
public struct AppConfig: Sendable {
    public let general: GeneralConfig
    public let proxies: [String: ServerConfig]   // name -> config
    public let groups: [ProxyGroup]
    public let rules: [Rule]
}

public struct GeneralConfig: Sendable {
    public let skipProxy: [String]
    public let dnsServer: String
    public let logLevel: String
}

public struct ProxyGroup: Sendable {
    public let name: String
    public let type: GroupType  // .select / .urlTest
    public let members: [String]
}

public enum Rule: Sendable {
    case domainSuffix(String, String)    // (suffix, policy)
    case domain(String, String)
    case ipCIDR(String, String)
    case geoIP(String, String)
    case ruleSet(URL, String)            // (url, policy)
    case final(String)
}
```

**Proxy 行解析示例:**

```text
🇭🇰香港-IEPL = ss, gd.bjnet2.com, 36602, encrypt-method=aes-128-gcm, password=xxx, obfs=http, obfs-host=xxx.baidu.com
🇯🇵 日本 | V1 | 01 = vmess, g3.merivox.net, 11101, username=ea03770f-..., alterId=0
```

**测试:** 解析包含 [General]、[Proxy]、[Proxy Group]、[Rule] 的完整配置文件。

---

## Task 2: 规则引擎（Router）

**文件:**
- `Sources/ShadowProxyCore/Router/Router.swift`
- `Sources/ShadowProxyCore/Router/RuleParser.swift`
- `Sources/ShadowProxyCore/Router/RuleSetLoader.swift`
- `Tests/ShadowProxyCoreTests/RouterTests.swift`

**目标:** 根据域名/IP 匹配规则，返回目标策略组。

**核心接口:**

```swift
public final class Router: Sendable {
    private let rules: [Rule]
    private let groups: [String: ProxyGroup]
    
    public init(rules: [Rule], groups: [String: ProxyGroup])
    
    /// 根据请求目标匹配规则，返回策略组名
    public func match(host: String, ip: String?) -> String
}
```

**RuleSetLoader:**
- HTTP 下载远程 .list 文件
- 本地缓存到 `~/.shadowproxy/rulesets/`
- 解析为 `[Rule]` 数组
- 启动时加载，后台定时刷新（1 小时）

**匹配优先级:** 按规则顺序遍历，首个命中即返回。FINAL 兜底。

**GEOIP 实现:**
- 使用 MaxMind GeoLite2-Country 数据库（mmdb 格式）
- 轻量级 mmdb 读取器，纯 Swift 实现（二进制树查找，无第三方依赖）
- 数据库文件放在 `~/.shadowproxy/GeoLite2-Country.mmdb`
- Phase 1 手动下载放置，Phase 2 自动更新

**测试:**
- DOMAIN-SUFFIX 匹配 `api.anthropic.com` → `🤖OpenAI`
- IP-CIDR 匹配 `10.6.0.1` → `DIRECT`
- GEOIP,CN 匹配中国 IP → `DIRECT`
- FINAL → `🐟漏网之鱼`

---

## Task 3: Shadowsocks 协议实现

**文件:**
- `Sources/ShadowProxyCore/Protocol/Shadowsocks.swift`
- `Sources/ShadowProxyCore/Crypto/AESGCM.swift`
- `Sources/ShadowProxyCore/Crypto/ObfsHTTP.swift`
- `Tests/ShadowProxyCoreTests/ShadowsocksTests.swift`

**目标:** 实现 Shadowsocks AEAD (aes-128-gcm) + obfs-http 插件。

**AEAD 协议流程:**
1. 生成随机 salt（16 bytes）
2. 用 HKDF 从 password 派生 subkey
3. 发送: `[salt][encrypted_payload]`
4. 每个 chunk: `[2-byte length (encrypted)][length tag][payload (encrypted)][payload tag]`

**加密核心（CryptoKit）:**

```swift
import CryptoKit

struct AESGCMCipher {
    let key: SymmetricKey
    var nonce: [UInt8]  // 12 bytes, 递增
    
    mutating func encrypt(_ plaintext: Data) throws -> Data
    mutating func decrypt(_ ciphertext: Data) throws -> Data
}
```

**obfs-http 插件:**
- 首个请求伪装为 HTTP GET 请求（Host: obfs-host）
- 首个响应解析 HTTP 头后提取 payload
- 后续数据直传

**测试:**
- HKDF 密钥派生正确性
- AES-128-GCM 加密/解密往返测试
- obfs-http 头部生成和解析

---

## Task 4: VMess 协议实现

**文件:**
- `Sources/ShadowProxyCore/Protocol/VMess.swift`
- `Sources/ShadowProxyCore/Crypto/AESCFB.swift`
- `Tests/ShadowProxyCoreTests/VMessTests.swift`

**目标:** 实现 VMess 协议（AEAD 版本，alterId=0）。

**VMess AEAD 握手流程:**
1. 生成随机 reqKey（16 bytes）+ reqIV（16 bytes）
2. 用 uuid 派生 cmdKey，AES-128-GCM 加密请求头（目标地址、端口、加密方式）
3. 请求头认证：`HMAC-MD5(timestamp, uuid)`
4. 数据传输：AES-128-GCM（security=auto 在 AEAD 模式下默认 GCM）或 ChaCha20-Poly1305

**加密支持:**
- `AES-128-GCM` — CryptoKit `AES.GCM`
- `ChaCha20-Poly1305` — CryptoKit `ChaChaPoly`
- `AES-128-CFB` — CommonCrypto 实现（兼容旧节点）

**AESCFB 实现（CommonCrypto）:**

```swift
import CommonCrypto

struct AESCFB {
    static func encrypt(_ data: Data, key: Data, iv: Data) throws -> Data
    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data
}
```

**测试:**
- VMess 请求头构造和加密正确性
- AES-CFB 加密/解密往返
- ChaCha20-Poly1305 加密/解密往返
- 时间戳认证头生成

---

## Task 5: Inbound（HTTP/SOCKS5 本地代理监听）

**文件:**
- `Sources/ShadowProxyCore/Engine/Inbound.swift`
- `Sources/ShadowProxyCore/Engine/HTTPProxy.swift`
- `Sources/ShadowProxyCore/Engine/SOCKS5Proxy.swift`
- `Tests/ShadowProxyCoreTests/InboundTests.swift`

**目标:** 用 NWListener 监听本地端口，解析 HTTP CONNECT 和 SOCKS5 请求。

**HTTP CONNECT 流程:**
1. 客户端发送 `CONNECT host:port HTTP/1.1\r\n\r\n`
2. 解析出目标 host 和 port
3. 回复 `HTTP/1.1 200 Connection Established\r\n\r\n`
4. 后续数据双向透传

**普通 HTTP 请求流程:**
1. 客户端发送 `GET http://host/path HTTP/1.1\r\n`
2. 解析出目标 host、port、path
3. 转发请求到代理节点，回传响应

**SOCKS5 流程:**
1. 握手：客户端 `05 01 00` → 服务端 `05 00`
2. 请求：`05 01 00 03 [domain_len][domain][port]`
3. 回复：`05 00 00 01 00000000 0000`
4. 双向透传

**核心接口:**

```swift
public final class Inbound {
    private let listener: NWListener
    private let router: Router
    private let onConnection: (ProxyTarget, String) async -> ProxySession?
    
    public init(port: UInt16, router: Router, onConnection: ...)
    public func start() throws
    public func stop()
}
```

**测试:**
- HTTP CONNECT 请求解析
- SOCKS5 握手和请求解析
- 普通 HTTP GET 请求解析

---

## Task 6: Outbound（代理连接与双向转发）

**文件:**
- `Sources/ShadowProxyCore/Engine/Outbound.swift`
- `Sources/ShadowProxyCore/Engine/Relay.swift`
- `Tests/ShadowProxyCoreTests/OutboundTests.swift`

**目标:** 根据策略组选择节点，建立代理连接，双向转发数据。

**设计说明：** 不做连接池。HTTP/SOCKS 代理模式下，每个客户端连接对应一个独立的代理连接，全程绑定转发直到结束。SSE 长连接可能持续几十秒，池化无意义且增加复杂度。

**Outbound:**

```swift
public final class Outbound {
    private let proxies: [String: ServerConfig]
    private let groups: [String: ProxyGroup]
    private let protocols: [String: any ProxyProtocol]
    
    /// 为指定目标创建代理连接并双向转发
    public func relay(
        target: ProxyTarget,
        policy: String,
        clientConnection: NWConnection
    ) async throws
}
```

**relay 核心逻辑:**
1. 从 policy 解析到具体节点 ServerConfig（支持策略组嵌套引用）
2. 用 NWConnection 建立到代理服务器的 TCP 连接
3. 调用 ProxyProtocol.connect() 完成代理握手
4. 启动双向转发（Relay）：client ↔ proxy

**Relay（双向数据转发）:**

```swift
struct Relay {
    /// 双向转发，直到任一方关闭或出错
    static func bridge(
        client: NWConnection,
        remote: NWConnection
    ) async throws
}
```

**长连接保护:**
- 转发建立后不设 idle timeout
- NWConnection 的 receive 是 async 等待，不会超时
- TCP keepalive 由 Network.framework 系统默认管理
- 连接只在对端关闭或网络错误时结束

**测试:**
- 策略组节点解析（包括嵌套引用）
- Relay 双向转发逻辑（mock connection）

---

## Task 7: ProxyEngine（主引擎）

**文件:**
- `Sources/ShadowProxyCore/Engine/ProxyEngine.swift`
- `Tests/ShadowProxyCoreTests/ProxyEngineTests.swift`

**目标:** 串联 Inbound → Router → Outbound，统一管理代理生命周期。

**核心接口:**

```swift
public final class ProxyEngine {
    private let config: AppConfig
    private let router: Router
    private let inbound: Inbound
    private let outbound: Outbound
    
    public init(config: AppConfig) async throws
    
    public func start() async throws   // 启动监听 + 加载规则
    public func stop() async           // 停止监听 + 关闭所有连接
    public func reload() async throws  // 重新加载配置
    
    /// 选择策略组节点
    public func select(group: String, node: String) throws
    
    /// 获取运行状态
    public func status() -> EngineStatus
}

public struct EngineStatus: Sendable {
    public let isRunning: Bool
    public let listenPort: UInt16
    public let activeConnections: Int
    public let selectedNodes: [String: String]  // group -> node
}
```

**请求处理流程:**
1. Inbound 收到客户端连接
2. 解析 HTTP CONNECT / SOCKS5 得到 ProxyTarget
3. Router.match(host) 得到 policy name
4. 如果 policy == "DIRECT" → 直连目标
5. 否则 → Outbound.relay() 通过代理节点转发
6. 代理域名不做本地 DNS，域名直接发给代理节点远端解析

**测试:**
- Engine 初始化和启停
- 配置重载

---

## Task 8: 系统代理设置 + 睡眠恢复

**文件:**
- `Sources/ShadowProxyCore/System/SystemProxy.swift`
- `Sources/ShadowProxyCore/System/SleepWatcher.swift`
- `Tests/ShadowProxyCoreTests/SystemProxyTests.swift`

**目标:** 启动时设置 macOS 系统代理，停止时还原。睡眠唤醒后检测并恢复连接。

**SystemProxy（SystemConfiguration 框架）:**

```swift
import SystemConfiguration

public struct SystemProxy {
    /// 设置系统 HTTP/SOCKS 代理为 127.0.0.1:port
    public static func enable(port: UInt16) throws
    
    /// 还原系统代理设置
    public static func disable() throws
    
    /// 检查系统代理是否指向我们
    public static func isEnabled(port: UInt16) -> Bool
}
```

**实现方式:** 通过 `networksetup` 命令设置（不需要 root 权限）：

```bash
# 设置 HTTP/HTTPS 代理
networksetup -setwebproxy "Wi-Fi" 127.0.0.1 7890
networksetup -setsecurewebproxy "Wi-Fi" 127.0.0.1 7890
networksetup -setsocksfirewallproxy "Wi-Fi" 127.0.0.1 7890
# 还原
networksetup -setwebproxystate "Wi-Fi" off
networksetup -setsecurewebproxystate "Wi-Fi" off
networksetup -setsocksfirewallproxystate "Wi-Fi" off
```

**自动检测网络服务名：** 通过 `SCDynamicStore` 读取当前活跃网络服务（Wi-Fi / Ethernet），不硬编码。

**SleepWatcher:**

```swift
public final class SleepWatcher {
    private let onWake: () async -> Void
    
    public init(onWake: @escaping () async -> Void)
    public func start()  // 注册 NSWorkspace 通知
    public func stop()
}
```

**唤醒恢复逻辑:**
1. 监听 `NSWorkspace.didWakeNotification`
2. 唤醒后等待 2 秒（网络恢复）
3. 检测系统代理是否还指向我们，如果不是则重新设置
4. 通过连接池 ping 检测已有连接可用性
5. 不可用的连接静默重建，不做全局重启

**测试:**
- 系统代理设置和还原
- 代理状态检测

---

## Task 9: CLI 入口 + 端到端集成

**文件:**
- `Sources/ShadowProxyCLI/main.swift`
- 测试配置文件 `~/.shadowproxy/config.conf`

**目标:** 实现 `sp` 命令行，串联所有模块，端到端可用。

**CLI 命令:**

```swift
import Foundation
import ShadowProxyCore

@main
struct ShadowProxyCLI {
    static func main() async throws {
        let args = CommandLine.arguments.dropFirst()
        guard let command = args.first else {
            printUsage()
            return
        }
        
        switch command {
        case "start":   try await start()
        case "stop":    try await stop()
        case "status":  try await status()
        case "select":  try await select(Array(args.dropFirst()))
        case "reload":  try await reload()
        case "test":    try await testLatency()
        default:        printUsage()
        }
    }
}
```

**`sp start` 流程:**
1. 读取 `~/.shadowproxy/config.conf`
2. ConfigParser 解析配置
3. RuleSetLoader 下载远程规则集
4. 创建 ProxyEngine 并启动
5. SystemProxy.enable() 设置系统代理
6. SleepWatcher.start() 监听睡眠
7. 写入 PID 到 `~/.shadowproxy/sp.pid`
8. 打印状态，保持前台运行（Ctrl+C 退出时清理）

**`sp stop` 流程:**
1. 读取 PID 文件
2. 发送 SIGTERM
3. 进程收到信号 → SystemProxy.disable() → Engine.stop()

**信号处理:**
- SIGTERM / SIGINT → 优雅退出（还原系统代理、关闭连接）
- SIGHUP → 重载配置

**端到端验证:**
1. 准备测试 config.conf（用真实节点）
2. `sp start` → 检查系统代理已设置
3. `curl -I https://api.anthropic.com` → 通过代理成功访问
4. 用 Claude Code 聊天测试延迟和稳定性
5. `sp stop` → 检查系统代理已还原

---

## 实现顺序与依赖

```
Task 1 (ConfigParser)
  ↓
Task 2 (Router) ← 依赖 Task 1 的 Rule 类型
  ↓
Task 3 (Shadowsocks) ← 独立，可与 Task 2 并行
Task 4 (VMess)       ← 独立，可与 Task 2/3 并行
  ↓
Task 5 (Inbound)     ← 依赖 Task 2 的 Router
Task 6 (ConnectionPool + Outbound) ← 依赖 Task 3/4 的协议
  ↓
Task 7 (ProxyEngine) ← 依赖 Task 1/2/5/6
  ↓
Task 8 (SystemProxy + SleepWatcher) ← 独立，可与 Task 7 并行
  ↓
Task 9 (CLI + 集成)  ← 依赖全部
```

**可并行的组:**
- Task 3 + Task 4（两个协议独立）
- Task 5 + Task 6（Inbound 和 Outbound 接口已定义）
- Task 7 + Task 8（引擎和系统集成独立）

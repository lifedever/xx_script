# ShadowProxy 批次1：传输层+协议补全 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 ShadowProxy 代理引擎达到生产级 — 支持 TLS/WebSocket 传输、VLESS/Trojan 协议、VMess padding、DoH DNS 防泄漏。

**Architecture:** 基于 Network.framework 原生 TLS/WebSocket（Safari 同源 TLS 指纹），在现有 Outbound 中抽取连接工厂方法统一管理传输层。新协议（VLESS/Trojan）利用 TLS 保护数据，协议本身极简。VMess 增加 SHAKE-128 masking + padding。

**Tech Stack:** Swift 6.0, Network.framework (NWProtocolTLS/NWProtocolWebSocket), CryptoKit, CommonCrypto, Swift Testing

**项目路径:** `shadowproxy/source/`，所有源码路径相对于 `Sources/ShadowProxyCore/`

---

### Task 1: TransportConfig 类型 + 配置解析

**Files:**
- Modify: `Sources/ShadowProxyCore/Protocol/ProxyProtocol.swift`
- Modify: `Sources/ShadowProxyCore/Config/ConfigParser.swift`
- Test: `Tests/ShadowProxyCoreTests/ConfigParserTests.swift`

- [ ] **Step 1: 在 ProxyProtocol.swift 新增 TransportConfig 和新协议 Config 类型**

在 `VMessConfig` 定义之后添加：

```swift
public struct TransportConfig: Sendable {
    public var tls: Bool
    public var tlsSNI: String?
    public var tlsALPN: [String]?
    public var tlsAllowInsecure: Bool
    public var wsPath: String?
    public var wsHost: String?

    public init(tls: Bool = false, tlsSNI: String? = nil, tlsALPN: [String]? = nil,
                tlsAllowInsecure: Bool = false, wsPath: String? = nil, wsHost: String? = nil) {
        self.tls = tls
        self.tlsSNI = tlsSNI
        self.tlsALPN = tlsALPN
        self.tlsAllowInsecure = tlsAllowInsecure
        self.wsPath = wsPath
        self.wsHost = wsHost
    }
}

public struct VLESSConfig: Sendable {
    public let server: String
    public let port: UInt16
    public let uuid: String
    public let transport: TransportConfig

    public init(server: String, port: UInt16, uuid: String, transport: TransportConfig = TransportConfig()) {
        self.server = server
        self.port = port
        self.uuid = uuid
        self.transport = transport
    }
}

public struct TrojanConfig: Sendable {
    public let server: String
    public let port: UInt16
    public let password: String
    public let transport: TransportConfig

    public init(server: String, port: UInt16, password: String, transport: TransportConfig = TransportConfig(tls: true)) {
        self.server = server
        self.port = port
        self.password = password
        // Trojan 强制 TLS
        var t = transport
        t.tls = true
        self.transport = t
    }
}
```

给现有 Config 加 transport 字段：

```swift
// ShadowsocksConfig 新增：
public let transport: TransportConfig
// init 新增参数 transport: TransportConfig = TransportConfig()

// VMessConfig 新增：
public let transport: TransportConfig
// init 新增参数 transport: TransportConfig = TransportConfig()
```

ServerConfig enum 扩展：

```swift
public enum ServerConfig: Sendable {
    case shadowsocks(ShadowsocksConfig)
    case vmess(VMessConfig)
    case vless(VLESSConfig)
    case trojan(TrojanConfig)
    case direct
}
```

- [ ] **Step 2: ConfigParser 新增 TransportConfig 提取 + vless/trojan 解析**

在 `ConfigParser.swift` 的 `parseProxies()` 方法中，在解析 key=value params 之后、switch proto 之前，提取公共传输配置：

```swift
// 在 switch proto 之前添加
let transport = TransportConfig(
    tls: params["tls"]?.lowercased() == "true",
    tlsSNI: params["sni"],
    tlsALPN: params["alpn"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
    tlsAllowInsecure: params["skip-cert-verify"]?.lowercased() == "true",
    wsPath: params["ws-path"],
    wsHost: params["ws-host"]
)
```

现有 ss/vmess case 传入 transport。新增 case：

```swift
case "vless":
    let config = VLESSConfig(
        server: server,
        port: port,
        uuid: params["uuid"] ?? "",
        transport: transport
    )
    result[name] = .vless(config)

case "trojan":
    let config = TrojanConfig(
        server: server,
        port: port,
        password: params["password"] ?? "",
        transport: transport
    )
    result[name] = .trojan(config)
```

- [ ] **Step 3: 写测试验证 VLESS/Trojan 配置解析**

在 `ConfigParserTests.swift` 添加：

```swift
@Test func parseVLESSProxy() throws {
    let conf = """
    [Proxy]
    JP-VLESS = vless, server.com, 443, uuid=ea03770f-be81-3903-b81d-19a0d0e8844f, tls=true, sni=server.com, ws-path=/ws
    """
    let config = try ConfigParser().parse(conf)
    guard case .vless(let v) = config.proxies["JP-VLESS"] else {
        Issue.record("Expected vless config")
        return
    }
    #expect(v.server == "server.com")
    #expect(v.port == 443)
    #expect(v.uuid == "ea03770f-be81-3903-b81d-19a0d0e8844f")
    #expect(v.transport.tls == true)
    #expect(v.transport.tlsSNI == "server.com")
    #expect(v.transport.wsPath == "/ws")
}

@Test func parseTrojanProxy() throws {
    let conf = """
    [Proxy]
    JP-Trojan = trojan, trojan.server.com, 443, password=mypassword, sni=trojan.server.com
    """
    let config = try ConfigParser().parse(conf)
    guard case .trojan(let t) = config.proxies["JP-Trojan"] else {
        Issue.record("Expected trojan config")
        return
    }
    #expect(t.server == "trojan.server.com")
    #expect(t.port == 443)
    #expect(t.password == "mypassword")
    #expect(t.transport.tls == true)  // Trojan 强制 TLS
    #expect(t.transport.tlsSNI == "trojan.server.com")
}

@Test func parseVMessWithTransport() throws {
    let conf = """
    [Proxy]
    JP-VMess = vmess, g3.merivox.net, 443, username=ea03770f-be81-3903-b81d-19a0d0e8844f, alterId=0, tls=true, sni=g3.merivox.net, ws-path=/vmess
    """
    let config = try ConfigParser().parse(conf)
    guard case .vmess(let v) = config.proxies["JP-VMess"] else {
        Issue.record("Expected vmess config")
        return
    }
    #expect(v.transport.tls == true)
    #expect(v.transport.wsPath == "/vmess")
}

@Test func existingConfigStillWorks() throws {
    let conf = """
    [Proxy]
    HK = ss, gd.bjnet2.com, 36602, encrypt-method=aes-128-gcm, password=test123, obfs=http, obfs-host=baidu.com
    JP = vmess, g3.merivox.net, 11101, username=ea03770f-be81-3903-b81d-19a0d0e8844f, alterId=0
    """
    let config = try ConfigParser().parse(conf)
    guard case .shadowsocks(let ss) = config.proxies["HK"] else {
        Issue.record("Expected ss"); return
    }
    #expect(ss.transport.tls == false)  // 默认无 TLS
    #expect(ss.transport.wsPath == nil)
    guard case .vmess(let vm) = config.proxies["JP"] else {
        Issue.record("Expected vmess"); return
    }
    #expect(vm.transport.tls == false)
}
```

- [ ] **Step 4: 运行测试**

Run: `cd shadowproxy/source && swift test --filter ConfigParserTests 2>&1 | tail -20`
Expected: 所有测试通过，包括新增的 4 个和原有的。

- [ ] **Step 5: Commit**

```bash
git add Sources/ShadowProxyCore/Protocol/ProxyProtocol.swift Sources/ShadowProxyCore/Config/ConfigParser.swift Tests/ShadowProxyCoreTests/ConfigParserTests.swift
git commit -m "feat: TransportConfig + VLESS/Trojan 配置解析"
```

---

### Task 2: 传输层连接工厂

**Files:**
- Modify: `Sources/ShadowProxyCore/Engine/Outbound.swift`

- [ ] **Step 1: 在 Outbound 中新增 createConnection() 方法**

在 `Outbound` 类中添加（在 `relay()` 方法之前）：

```swift
/// 根据 TransportConfig 创建 NWConnection（支持裸 TCP / TLS / WebSocket / TLS+WebSocket）
private func createConnection(server: String, port: UInt16, transport: TransportConfig) -> NWConnection {
    let host = NWEndpoint.Host(server)
    let nwPort = NWEndpoint.Port(rawValue: port)!

    if transport.tls {
        // TLS
        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions

        // SNI
        let sni = transport.tlsSNI ?? server
        sec_protocol_options_set_tls_server_name(secOptions, sni)

        // ALPN
        if let alpns = transport.tlsALPN {
            for alpn in alpns {
                sec_protocol_options_add_tls_application_protocol(secOptions, alpn)
            }
        }

        // Skip cert verify
        if transport.tlsAllowInsecure {
            sec_protocol_options_set_verify_block(secOptions, { _, _, completionHandler in
                completionHandler(true)
            }, queue)
        }

        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        // WebSocket over TLS
        if let wsPath = transport.wsPath {
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            wsOptions.setAdditionalHeaders(buildWSHeaders(host: transport.wsHost ?? sni, path: wsPath))
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        }

        return NWConnection(host: host, port: nwPort, using: params)
    } else if let wsPath = transport.wsPath {
        // WebSocket without TLS
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.setAdditionalHeaders(buildWSHeaders(host: transport.wsHost ?? server, path: wsPath))
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        return NWConnection(host: host, port: nwPort, using: params)
    } else {
        // 裸 TCP（现有行为）
        return NWConnection(host: host, port: nwPort, using: .tcp)
    }
}

private func buildWSHeaders(host: String, path: String) -> [(String, String)] {
    [
        ("Host", host),
        ("Upgrade", "websocket"),
    ]
}
```

- [ ] **Step 2: 替换现有三处裸 TCP 连接创建**

将 `relayDirect()` 中的：
```swift
let remote = NWConnection(
    host: NWEndpoint.Host(target.host),
    port: NWEndpoint.Port(rawValue: target.port)!,
    using: .tcp
)
```
替换为：
```swift
let remote = NWConnection(
    host: NWEndpoint.Host(target.host),
    port: NWEndpoint.Port(rawValue: target.port)!,
    using: .tcp
)
```
（DIRECT 保持裸 TCP 不变）

将 `relayShadowsocks()` 中的 NWConnection 创建替换为：
```swift
let remote = createConnection(server: config.server, port: config.port, transport: config.transport)
```

将 `relayVMess()` 中的 NWConnection 创建替换为：
```swift
let remote = createConnection(server: config.server, port: config.port, transport: config.transport)
```

- [ ] **Step 3: 运行全量测试确保不回归**

Run: `cd shadowproxy/source && swift test 2>&1 | tail -20`
Expected: 所有测试通过

- [ ] **Step 4: Commit**

```bash
git add Sources/ShadowProxyCore/Engine/Outbound.swift
git commit -m "feat: 传输层连接工厂，支持 TLS/WebSocket/TLS+WS"
```

---

### Task 3: VLESS 协议实现

**Files:**
- Create: `Sources/ShadowProxyCore/Protocol/VLESS.swift`
- Modify: `Sources/ShadowProxyCore/Engine/Outbound.swift`
- Test: `Tests/ShadowProxyCoreTests/VLESSTests.swift`

- [ ] **Step 1: 写 VLESS 协议头构建测试**

创建 `Tests/ShadowProxyCoreTests/VLESSTests.swift`：

```swift
import Testing
import Foundation
@testable import ShadowProxyCore

@Test func vlessRequestHeader() throws {
    let target = ProxyTarget(host: "example.com", port: 443)
    let uuid = "ea03770f-be81-3903-b81d-19a0d0e8844f"
    let header = try VLESSHeader.buildRequest(uuid: uuid, target: target)

    // version = 0x00
    #expect(header[0] == 0x00)
    // uuid = 16 bytes
    #expect(header[1] == 0xea)
    #expect(header[2] == 0x03)
    // addons_len = 0
    #expect(header[17] == 0x00)
    // command = 0x01 (TCP)
    #expect(header[18] == 0x01)
    // port = 443 big-endian
    #expect(header[19] == 0x01)
    #expect(header[20] == 0xBB)
    // addr_type = 0x02 (domain)
    #expect(header[21] == 0x02)
    // domain length
    #expect(header[22] == UInt8("example.com".utf8.count))
    // total size: 1 + 16 + 1 + 1 + 2 + 1 + 1 + 11 = 34
    #expect(header.count == 34)
}

@Test func vlessRequestHeaderIPv4() throws {
    let target = ProxyTarget(host: "1.2.3.4", port: 80)
    let uuid = "ea03770f-be81-3903-b81d-19a0d0e8844f"
    let header = try VLESSHeader.buildRequest(uuid: uuid, target: target)

    // addr_type = 0x01 (IPv4)
    #expect(header[21] == 0x01)
    // 4 bytes IPv4
    #expect(header[22] == 1)
    #expect(header[23] == 2)
    #expect(header[24] == 3)
    #expect(header[25] == 4)
    // total: 1 + 16 + 1 + 1 + 2 + 1 + 4 = 26
    #expect(header.count == 26)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd shadowproxy/source && swift test --filter VLESSTests 2>&1 | tail -5`
Expected: FAIL — VLESSHeader 未定义

- [ ] **Step 3: 实现 VLESS.swift**

创建 `Sources/ShadowProxyCore/Protocol/VLESS.swift`：

```swift
import Foundation

/// VLESS protocol header construction
/// VLESS 不做加密，完全依赖 TLS 传输层
///
/// Request: [version(1)][uuid(16)][addons_len(1)][command(1)][port(2)][addr_type(1)][addr(N)]
/// Response: [version(1)][addons_len(1)][addons(N)]
public struct VLESSHeader: Sendable {

    /// Build VLESS request header
    public static func buildRequest(uuid: String, target: ProxyTarget) throws -> Data {
        let uuidBytes = try VMessHeader.parseUUID(uuid)  // 复用 VMess 的 UUID 解析

        var header = Data()
        // Version
        header.append(0x00)
        // UUID (16 bytes)
        header.append(contentsOf: uuidBytes)
        // Addons length (0 = no addons)
        header.append(0x00)
        // Command: 0x01 = TCP
        header.append(0x01)
        // Port (big-endian)
        header.append(UInt8(target.port >> 8))
        header.append(UInt8(target.port & 0xFF))
        // Address
        appendAddress(target.host, to: &header)

        return header
    }

    /// Parse VLESS response header, return bytes consumed
    /// Response: [version(1)][addons_len(1)][addons(N)]
    public static func parseResponse(_ buffer: Data) -> Int? {
        guard buffer.count >= 2 else { return nil }
        let addonsLen = Int(buffer[buffer.startIndex + 1])
        let totalLen = 2 + addonsLen
        guard buffer.count >= totalLen else { return nil }
        return totalLen
    }

    /// Append address in VLESS format: [type(1)][addr(N)]
    private static func appendAddress(_ host: String, to data: inout Data) {
        // Try IPv4
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            data.append(0x01)  // IPv4
            for part in parts {
                data.append(UInt8(part)!)
            }
            return
        }

        // Domain
        let domainBytes = Data(host.utf8)
        data.append(0x02)  // Domain
        data.append(UInt8(domainBytes.count))
        data.append(contentsOf: domainBytes)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd shadowproxy/source && swift test --filter VLESSTests 2>&1 | tail -10`
Expected: 2 tests PASS

- [ ] **Step 5: 在 Outbound 添加 relayVLESS**

在 `Outbound.swift` 的 `relay()` 方法 switch 中添加：

```swift
case .vless(let config):
    splog.debug("VLESS → \(config.server):\(config.port) → \(target.host):\(target.port)", tag: "Outbound")
    try await relayVLESS(client: client, target: target, config: config, initialData: initialData)
```

新增方法：

```swift
// MARK: - VLESS

private func relayVLESS(client: NWConnection, target: ProxyTarget, config: VLESSConfig, initialData: Data?) async throws {
    let remote = createConnection(server: config.server, port: config.port, transport: config.transport)
    try await remote.connectAsync(queue: queue)
    splog.debug("VLESS connected to \(config.server):\(config.port)", tag: "VLESS")

    // Send VLESS request header
    let header = try VLESSHeader.buildRequest(uuid: config.uuid, target: target)

    // If there's initial data, append it to header to send in one packet
    var firstPacket = header
    if let data = initialData {
        firstPacket.append(data)
    }
    try await Relay.sendData(firstPacket, to: remote)

    // Read and consume VLESS response header
    let respData = try await Relay.receiveData(from: remote)
    guard let consumed = VLESSHeader.parseResponse(respData) else {
        splog.error("VLESS response header parse failed", tag: "VLESS")
        remote.cancel()
        client.cancel()
        return
    }

    // If response contained extra data beyond the header, forward it to client
    if consumed < respData.count {
        let extra = respData[respData.startIndex + consumed...]
        try await Relay.sendData(Data(extra), to: client)
    }

    // Bidirectional relay — VLESS is raw data after handshake
    await Relay.bridge(client: client, remote: remote)
}
```

- [ ] **Step 6: 运行全量测试**

Run: `cd shadowproxy/source && swift test 2>&1 | tail -20`
Expected: 所有测试通过

- [ ] **Step 7: Commit**

```bash
git add Sources/ShadowProxyCore/Protocol/VLESS.swift Sources/ShadowProxyCore/Engine/Outbound.swift Tests/ShadowProxyCoreTests/VLESSTests.swift
git commit -m "feat: VLESS 协议实现"
```

---

### Task 4: Trojan 协议实现

**Files:**
- Create: `Sources/ShadowProxyCore/Protocol/Trojan.swift`
- Modify: `Sources/ShadowProxyCore/Engine/Outbound.swift`
- Test: `Tests/ShadowProxyCoreTests/TrojanTests.swift`

- [ ] **Step 1: 写 Trojan 协议头构建测试**

创建 `Tests/ShadowProxyCoreTests/TrojanTests.swift`：

```swift
import Testing
import Foundation
import CommonCrypto
@testable import ShadowProxyCore

@Test func trojanPasswordHash() {
    let hash = TrojanHeader.sha224Hex("mypassword")
    // SHA-224 of "mypassword" = known hex string, 56 chars
    #expect(hash.count == 56)
    // Verify it's valid hex
    #expect(hash.allSatisfy { "0123456789abcdef".contains($0) })
    // Deterministic
    #expect(hash == TrojanHeader.sha224Hex("mypassword"))
}

@Test func trojanRequestHeader() throws {
    let target = ProxyTarget(host: "example.com", port: 443)
    let header = TrojanHeader.buildRequest(password: "mypassword", target: target)
    let passwordHash = TrojanHeader.sha224Hex("mypassword")

    // First 56 bytes: SHA224 hex of password
    let hashPart = String(data: header.prefix(56), encoding: .ascii)!
    #expect(hashPart == passwordHash)

    // Next 2 bytes: CRLF
    #expect(header[56] == 0x0D)
    #expect(header[57] == 0x0A)

    // Command: 0x01 (TCP CONNECT)
    #expect(header[58] == 0x01)

    // addr_type: 0x03 (domain, SOCKS5 format)
    #expect(header[59] == 0x03)

    // domain length
    #expect(header[60] == UInt8("example.com".utf8.count))

    // domain bytes
    let domainStart = 61
    let domainEnd = domainStart + Int(header[60])
    let domain = String(data: header[domainStart..<domainEnd], encoding: .utf8)
    #expect(domain == "example.com")

    // port (big-endian) after domain
    let portHi = header[domainEnd]
    let portLo = header[domainEnd + 1]
    #expect(UInt16(portHi) << 8 | UInt16(portLo) == 443)

    // Trailing CRLF
    #expect(header[domainEnd + 2] == 0x0D)
    #expect(header[domainEnd + 3] == 0x0A)
}

@Test func trojanRequestHeaderIPv4() throws {
    let target = ProxyTarget(host: "1.2.3.4", port: 80)
    let header = TrojanHeader.buildRequest(password: "test", target: target)

    // After CRLF + command: addr_type = 0x01 (IPv4)
    #expect(header[59] == 0x01)
    #expect(header[60] == 1)
    #expect(header[61] == 2)
    #expect(header[62] == 3)
    #expect(header[63] == 4)
    // Port
    #expect(header[64] == 0x00)
    #expect(header[65] == 80)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd shadowproxy/source && swift test --filter TrojanTests 2>&1 | tail -5`
Expected: FAIL — TrojanHeader 未定义

- [ ] **Step 3: 实现 Trojan.swift**

创建 `Sources/ShadowProxyCore/Protocol/Trojan.swift`：

```swift
import Foundation
import CommonCrypto

/// Trojan protocol header construction
/// Trojan 伪装为 HTTPS 流量，强制 TLS
///
/// Request: [sha224_hex(56)][CRLF][cmd(1)][addr_type(1)][addr(N)][port(2)][CRLF]
/// No response header — data starts immediately after request
public struct TrojanHeader: Sendable {

    /// SHA-224 hex digest of password (56 ASCII chars)
    public static func sha224Hex(_ password: String) -> String {
        let data = Data(password.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA224(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Build Trojan request header
    public static func buildRequest(password: String, target: ProxyTarget) -> Data {
        var header = Data()

        // SHA224 hex of password (56 bytes ASCII)
        header.append(contentsOf: Data(sha224Hex(password).utf8))
        // CRLF
        header.append(contentsOf: [0x0D, 0x0A])
        // Command: 0x01 = TCP CONNECT
        header.append(0x01)
        // Address (SOCKS5 format)
        appendSOCKS5Address(target.host, to: &header)
        // Port (big-endian)
        header.append(UInt8(target.port >> 8))
        header.append(UInt8(target.port & 0xFF))
        // CRLF
        header.append(contentsOf: [0x0D, 0x0A])

        return header
    }

    /// Append address in SOCKS5 format: [type(1)][addr(N)]
    private static func appendSOCKS5Address(_ host: String, to data: inout Data) {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            // IPv4
            data.append(0x01)
            for part in parts {
                data.append(UInt8(part)!)
            }
            return
        }
        // Domain
        let domainBytes = Data(host.utf8)
        data.append(0x03)
        data.append(UInt8(domainBytes.count))
        data.append(contentsOf: domainBytes)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd shadowproxy/source && swift test --filter TrojanTests 2>&1 | tail -10`
Expected: 3 tests PASS

- [ ] **Step 5: 在 Outbound 添加 relayTrojan**

在 `Outbound.swift` 的 `relay()` switch 中添加：

```swift
case .trojan(let config):
    splog.debug("Trojan → \(config.server):\(config.port) → \(target.host):\(target.port)", tag: "Outbound")
    try await relayTrojan(client: client, target: target, config: config, initialData: initialData)
```

新增方法：

```swift
// MARK: - Trojan

private func relayTrojan(client: NWConnection, target: ProxyTarget, config: TrojanConfig, initialData: Data?) async throws {
    let remote = createConnection(server: config.server, port: config.port, transport: config.transport)
    try await remote.connectAsync(queue: queue)
    splog.debug("Trojan connected to \(config.server):\(config.port)", tag: "Trojan")

    // Send Trojan request header (+ initial data if any)
    var firstPacket = TrojanHeader.buildRequest(password: config.password, target: target)
    if let data = initialData {
        firstPacket.append(data)
    }
    try await Relay.sendData(firstPacket, to: remote)

    // No response header — Trojan is raw data after request
    await Relay.bridge(client: client, remote: remote)
}
```

- [ ] **Step 6: 运行全量测试**

Run: `cd shadowproxy/source && swift test 2>&1 | tail -20`
Expected: 所有测试通过

- [ ] **Step 7: Commit**

```bash
git add Sources/ShadowProxyCore/Protocol/Trojan.swift Sources/ShadowProxyCore/Engine/Outbound.swift Tests/ShadowProxyCoreTests/TrojanTests.swift
git commit -m "feat: Trojan 协议实现"
```

---

### Task 5: SHAKE-128 + VMess Padding (0x05/0x1D)

**Files:**
- Create: `Sources/ShadowProxyCore/Crypto/SHAKE128.swift`
- Modify: `Sources/ShadowProxyCore/Protocol/VMess.swift`
- Test: `Tests/ShadowProxyCoreTests/SHAKE128Tests.swift`
- Modify: `Tests/ShadowProxyCoreTests/VMessTests.swift`

- [ ] **Step 1: 写 SHAKE-128 测试（NIST 向量）**

创建 `Tests/ShadowProxyCoreTests/SHAKE128Tests.swift`：

```swift
import Testing
import Foundation
@testable import ShadowProxyCore

@Test func shake128EmptyInput() {
    // NIST: SHAKE128("") first 32 bytes
    var shake = SHAKE128()
    shake.absorb(Data())
    let output = shake.squeeze(count: 32)
    let hex = output.map { String(format: "%02x", $0) }.joined()
    // Known NIST vector for SHAKE128("")
    #expect(hex.hasPrefix("7f9c2ba4e88f827d"))
}

@Test func shake128KnownInput() {
    // SHAKE128("abc") first 16 bytes
    var shake = SHAKE128()
    shake.absorb(Data("abc".utf8))
    let output = shake.squeeze(count: 16)
    let hex = output.map { String(format: "%02x", $0) }.joined()
    #expect(hex.hasPrefix("5881092dd818bf5c"))
}

@Test func shake128StreamOutput() {
    // Squeeze in multiple calls should produce same stream as single call
    var shake1 = SHAKE128()
    shake1.absorb(Data("test".utf8))
    let full = shake1.squeeze(count: 32)

    var shake2 = SHAKE128()
    shake2.absorb(Data("test".utf8))
    let part1 = shake2.squeeze(count: 16)
    let part2 = shake2.squeeze(count: 16)

    #expect(full == part1 + part2)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd shadowproxy/source && swift test --filter SHAKE128Tests 2>&1 | tail -5`
Expected: FAIL — SHAKE128 未定义

- [ ] **Step 3: 实现 SHAKE128.swift（Keccak sponge XOF）**

创建 `Sources/ShadowProxyCore/Crypto/SHAKE128.swift`：

```swift
import Foundation

/// SHAKE-128 extendable-output function (XOF)
/// Keccak sponge with rate=168, capacity=32, padding=0x1F
public struct SHAKE128: Sendable {
    private var state = [UInt64](repeating: 0, count: 25)  // 5x5 Keccak state
    private var absorbed = false
    private var squeezeOffset = 0
    private var squeezeBuffer = Data()

    private let rate = 168  // bytes (1344 bits for SHAKE128)

    public init() {}

    /// Absorb input data
    public mutating func absorb(_ data: Data) {
        var input = data
        var offset = 0

        while offset < input.count {
            let blockSize = min(rate, input.count - offset)
            let block = input[offset..<(offset + blockSize)]

            // XOR block into state
            for i in 0..<blockSize {
                let stateIdx = i / 8
                let byteIdx = i % 8
                state[stateIdx] ^= UInt64(block[block.startIndex + i]) << (byteIdx * 8)
            }

            offset += blockSize

            if blockSize == rate {
                keccakF1600()
            }
        }

        // Pad and finalize (SHAKE padding: 0x1F)
        let remaining = offset % rate == 0 && !data.isEmpty ? rate : offset % rate
        let padPos = data.count % rate
        state[padPos / 8] ^= UInt64(0x1F) << ((padPos % 8) * 8)
        state[(rate - 1) / 8] ^= UInt64(0x80) << (((rate - 1) % 8) * 8)
        keccakF1600()

        absorbed = true
        squeezeOffset = 0
        squeezeBuffer = stateToBytes()
    }

    /// Squeeze output bytes
    public mutating func squeeze(count: Int) -> Data {
        guard absorbed else { return Data(repeating: 0, count: count) }

        var output = Data()
        while output.count < count {
            if squeezeOffset >= rate {
                keccakF1600()
                squeezeBuffer = stateToBytes()
                squeezeOffset = 0
            }
            let available = min(rate - squeezeOffset, count - output.count)
            output.append(squeezeBuffer[squeezeOffset..<(squeezeOffset + available)])
            squeezeOffset += available
        }
        return output
    }

    private func stateToBytes() -> Data {
        var bytes = Data(count: 200)
        for i in 0..<25 {
            var val = state[i]
            for j in 0..<8 {
                bytes[i * 8 + j] = UInt8(val & 0xFF)
                val >>= 8
            }
        }
        return bytes
    }

    // MARK: - Keccak-f[1600]

    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]

    private static let rotationOffsets: [[Int]] = [
        [ 0,  1, 62, 28, 27],
        [36, 44,  6, 55, 20],
        [ 3, 10, 43, 25, 39],
        [41, 45, 15, 21,  8],
        [18,  2, 61, 56, 14],
    ]

    private mutating func keccakF1600() {
        for round in 0..<24 {
            // θ (theta)
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1)
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + y * 5] ^= d[x]
                }
            }

            // ρ (rho) + π (pi)
            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + ((2 * x + 3 * y) % 5) * 5] = rotl64(state[x + y * 5], Self.rotationOffsets[y][x])
                }
            }

            // χ (chi)
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + y * 5] = b[x + y * 5] ^ (~b[(x + 1) % 5 + y * 5] & b[(x + 2) % 5 + y * 5])
                }
            }

            // ι (iota)
            state[0] ^= Self.roundConstants[round]
        }
    }

    private func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }
}
```

- [ ] **Step 4: 运行 SHAKE-128 测试**

Run: `cd shadowproxy/source && swift test --filter SHAKE128Tests 2>&1 | tail -10`
Expected: 3 tests PASS

- [ ] **Step 5: 在 VMessConfig 添加 option 枚举**

在 `ProxyProtocol.swift` 的 `VMessConfig` 中添加：

```swift
public enum VMessOption: UInt8, Sendable {
    case chunkStream = 0x01                // 明文长度 + GCM payload
    case chunkMasking = 0x05               // SHAKE mask + GCM 长度 + GCM payload
    case chunkMaskingPadding = 0x1D        // SHAKE mask + GCM 长度 + GCM (payload + padding)
}

// VMessConfig 新增字段：
public let option: VMessOption  // 默认 .chunkMaskingPadding
// init 新增参数：option: VMessOption = .chunkMaskingPadding
```

- [ ] **Step 6: 修改 VMessDataCipher 支持 0x05/0x1D**

在 `VMess.swift` 中修改 `VMessDataCipher`：

```swift
public struct VMessDataCipher: Sendable {
    private var dataCipher: VMessGCM
    private let option: VMessOption
    private var shakeMask: SHAKE128?       // For 0x05/0x1D
    private var shakePadding: SHAKE128?    // For 0x1D only

    public init(key: Data, iv: Data, security: VMessSecurity = .aes128gcm, option: VMessOption = .chunkStream) {
        self.dataCipher = VMessGCM(key: key, iv: iv)
        self.option = option

        if option == .chunkMasking || option == .chunkMaskingPadding {
            var mask = SHAKE128()
            mask.absorb(iv)
            self.shakeMask = mask
        }
        if option == .chunkMaskingPadding {
            var pad = SHAKE128()
            pad.absorb(iv)
            self.shakePadding = pad
        }
    }

    public mutating func encrypt(_ plaintext: Data) throws -> Data {
        switch option {
        case .chunkStream:
            return try encryptChunkStream(plaintext)
        case .chunkMasking:
            return try encryptChunkMasking(plaintext, withPadding: false)
        case .chunkMaskingPadding:
            return try encryptChunkMasking(plaintext, withPadding: true)
        }
    }

    // 0x01: [plain 2-byte length][GCM payload]
    private mutating func encryptChunkStream(_ plaintext: Data) throws -> Data {
        let encPayload = try dataCipher.encrypt(plaintext)
        let encLen = UInt16(encPayload.count)
        var chunk = Data([UInt8(encLen >> 8), UInt8(encLen & 0xFF)])
        chunk.append(encPayload)
        return chunk
    }

    // 0x05/0x1D: [GCM(masked 2-byte length)][GCM(payload + optional padding)]
    private mutating func encryptChunkMasking(_ plaintext: Data, withPadding: Bool) throws -> Data {
        var payload = plaintext

        // 0x1D: append random padding
        var paddingLen: UInt16 = 0
        if withPadding {
            let padBytes = shakePadding!.squeeze(count: 2)
            paddingLen = (UInt16(padBytes[0]) << 8 | UInt16(padBytes[1])) % 64
            if paddingLen > 0 {
                payload.append(Data((0..<paddingLen).map { _ in UInt8.random(in: 0...255) }))
            }
        }

        // Encrypt payload
        let encPayload = try dataCipher.encrypt(payload)

        // Length = actual plaintext length (NOT including padding)
        let realLen = UInt16(plaintext.count)
        var lenBytes = Data([UInt8(realLen >> 8), UInt8(realLen & 0xFF)])

        // SHAKE-128 mask XOR on length
        let maskBytes = shakeMask!.squeeze(count: 2)
        lenBytes[0] ^= maskBytes[0]
        lenBytes[1] ^= maskBytes[1]

        // GCM encrypt the masked length (2 bytes → 18 bytes)
        let encLen = try dataCipher.encrypt(lenBytes)

        var chunk = encLen
        chunk.append(encPayload)
        return chunk
    }

    public mutating func decryptChunk(from buffer: Data) throws -> (Data, Int)? {
        switch option {
        case .chunkStream:
            return try decryptChunkStream(from: buffer)
        case .chunkMasking:
            return try decryptChunkMasking(from: buffer, hasPadding: false)
        case .chunkMaskingPadding:
            return try decryptChunkMasking(from: buffer, hasPadding: true)
        }
    }

    // 0x01
    private mutating func decryptChunkStream(from buffer: Data) throws -> (Data, Int)? {
        guard buffer.count >= 2 else { return nil }
        let encPayloadLen = Int(UInt16(buffer[buffer.startIndex]) << 8 | UInt16(buffer[buffer.startIndex + 1]))
        guard encPayloadLen > 0 else { return (Data(), 2) }
        let totalChunkSize = 2 + encPayloadLen
        guard buffer.count >= totalChunkSize else { return nil }
        let encPayload = Data(buffer[(buffer.startIndex + 2)..<(buffer.startIndex + totalChunkSize)])
        let plaintext = try dataCipher.decrypt(encPayload)
        return (plaintext, totalChunkSize)
    }

    // 0x05/0x1D
    private mutating func decryptChunkMasking(from buffer: Data, hasPadding: Bool) throws -> (Data, Int)? {
        // Need 18 bytes for GCM-encrypted length
        guard buffer.count >= 18 else { return nil }
        let encLenData = Data(buffer[buffer.startIndex..<(buffer.startIndex + 18)])

        // Decrypt length
        var lenBytes = try dataCipher.decrypt(encLenData)

        // Unmask with SHAKE-128
        let maskBytes = shakeMask!.squeeze(count: 2)
        lenBytes[0] ^= maskBytes[0]
        lenBytes[1] ^= maskBytes[1]

        let realLen = Int(UInt16(lenBytes[0]) << 8 | UInt16(lenBytes[1]))
        guard realLen > 0 else { return (Data(), 18) }

        // Calculate padding length for 0x1D
        var paddingLen = 0
        if hasPadding {
            let padBytes = shakePadding!.squeeze(count: 2)
            paddingLen = Int((UInt16(padBytes[0]) << 8 | UInt16(padBytes[1])) % 64)
        }

        // Total encrypted payload = GCM(realLen + paddingLen) = (realLen + paddingLen + 16)
        let encPayloadSize = realLen + paddingLen + 16
        let totalChunkSize = 18 + encPayloadSize
        guard buffer.count >= totalChunkSize else { return nil }

        let encPayload = Data(buffer[(buffer.startIndex + 18)..<(buffer.startIndex + totalChunkSize)])
        let decrypted = try dataCipher.decrypt(encPayload)

        // Strip padding, return only real data
        let plaintext = decrypted.prefix(realLen)
        return (Data(plaintext), totalChunkSize)
    }
}
```

- [ ] **Step 7: 修改 VMessHeader.buildRequest 使用 option**

在 `VMess.swift` 中 `buildRequest` 方法里，将：
```swift
cmd.append(0x01)
```
改为接受参数：
```swift
cmd.append(option.rawValue)
```

同时给 `buildRequest` 添加 `option: VMessOption = .chunkMaskingPadding` 参数。

- [ ] **Step 8: 写 VMess padding round-trip 测试**

在 `VMessTests.swift` 添加：

```swift
@Test func vmessChunkMaskingRoundTrip() throws {
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let plaintext = Data("Hello VMess ChunkMasking!".utf8)

    var encCipher = VMessDataCipher(key: key, iv: iv, option: .chunkMasking)
    let chunk = try encCipher.encrypt(plaintext)

    var decCipher = VMessDataCipher(key: key, iv: iv, option: .chunkMasking)
    let result = try decCipher.decryptChunk(from: chunk)

    #expect(result != nil)
    #expect(result!.0 == plaintext)
    #expect(result!.1 == chunk.count)
}

@Test func vmessChunkMaskingPaddingRoundTrip() throws {
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let plaintext = Data("Hello VMess Padding!".utf8)

    var encCipher = VMessDataCipher(key: key, iv: iv, option: .chunkMaskingPadding)
    let chunk = try encCipher.encrypt(plaintext)

    var decCipher = VMessDataCipher(key: key, iv: iv, option: .chunkMaskingPadding)
    let result = try decCipher.decryptChunk(from: chunk)

    #expect(result != nil)
    #expect(result!.0 == plaintext)
    // Chunk should be larger than chunkMasking due to padding
    #expect(chunk.count >= 18 + plaintext.count + 16)
}

@Test func vmessOption01StillWorks() throws {
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let plaintext = Data("Legacy option 0x01".utf8)

    var encCipher = VMessDataCipher(key: key, iv: iv, option: .chunkStream)
    let chunk = try encCipher.encrypt(plaintext)

    var decCipher = VMessDataCipher(key: key, iv: iv, option: .chunkStream)
    let result = try decCipher.decryptChunk(from: chunk)

    #expect(result != nil)
    #expect(result!.0 == plaintext)
}
```

- [ ] **Step 9: 运行全量测试**

Run: `cd shadowproxy/source && swift test 2>&1 | tail -20`
Expected: 所有测试通过

- [ ] **Step 10: Commit**

```bash
git add Sources/ShadowProxyCore/Crypto/SHAKE128.swift Sources/ShadowProxyCore/Protocol/VMess.swift Sources/ShadowProxyCore/Protocol/ProxyProtocol.swift Tests/ShadowProxyCoreTests/SHAKE128Tests.swift Tests/ShadowProxyCoreTests/VMessTests.swift
git commit -m "feat: SHAKE-128 + VMess 0x05/0x1D padding 支持"
```

---

### Task 6: DoH DNS 防泄漏

**Files:**
- Create: `Sources/ShadowProxyCore/Engine/DoHResolver.swift`
- Modify: `Sources/ShadowProxyCore/Engine/Outbound.swift`
- Test: `Tests/ShadowProxyCoreTests/DoHResolverTests.swift`

- [ ] **Step 1: 写 DoH DNS 查询构建测试**

创建 `Tests/ShadowProxyCoreTests/DoHResolverTests.swift`：

```swift
import Testing
import Foundation
@testable import ShadowProxyCore

@Test func dohBuildQuery() {
    let query = DoHResolver.buildDNSQuery(domain: "example.com")
    // DNS header: 12 bytes + question section
    #expect(query.count > 12)
    // First 2 bytes: transaction ID (random)
    // Bytes 2-3: flags = 0x0100 (standard query, recursion desired)
    #expect(query[2] == 0x01)
    #expect(query[3] == 0x00)
    // Bytes 4-5: QDCOUNT = 1
    #expect(query[4] == 0x00)
    #expect(query[5] == 0x01)
}

@Test func dohParseResponse() throws {
    // Manually construct a minimal DNS response with one A record
    // example.com → 93.184.216.34
    var response = Data()
    // Header: ID=0x1234, flags=0x8180 (response, no error), QD=1, AN=1, NS=0, AR=0
    response.append(contentsOf: [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
    // Question: example.com, type A, class IN
    response.append(contentsOf: [7]) // "example" length
    response.append(contentsOf: "example".utf8)
    response.append(contentsOf: [3]) // "com" length
    response.append(contentsOf: "com".utf8)
    response.append(contentsOf: [0x00]) // root
    response.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // type A, class IN
    // Answer: pointer to question name, type A, class IN, TTL=300, RDLENGTH=4, RDATA=93.184.216.34
    response.append(contentsOf: [0xC0, 0x0C]) // name pointer
    response.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // type A, class IN
    response.append(contentsOf: [0x00, 0x00, 0x01, 0x2C]) // TTL=300
    response.append(contentsOf: [0x00, 0x04]) // RDLENGTH=4
    response.append(contentsOf: [93, 184, 216, 34]) // IP

    let ip = try DoHResolver.parseARecord(response)
    #expect(ip == "93.184.216.34")
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd shadowproxy/source && swift test --filter DoHResolverTests 2>&1 | tail -5`
Expected: FAIL — DoHResolver 未定义

- [ ] **Step 3: 实现 DoHResolver.swift**

创建 `Sources/ShadowProxyCore/Engine/DoHResolver.swift`：

```swift
import Foundation

/// DNS-over-HTTPS resolver (RFC 8484)
/// 仅用于 DIRECT 连接，避免系统 DNS 泄漏
public final class DoHResolver: @unchecked Sendable {
    private let serverURL: String
    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    private struct CacheEntry {
        let ip: String
        let expiry: Date
    }

    public init(server: String = "https://223.5.5.5/dns-query") {
        self.serverURL = server
    }

    /// Resolve domain to IPv4 address via DoH
    public func resolve(_ domain: String) async throws -> String {
        // Check cache
        lock.lock()
        if let entry = cache[domain], entry.expiry > Date() {
            lock.unlock()
            return entry.ip
        }
        lock.unlock()

        // Build DNS query
        let query = Self.buildDNSQuery(domain: domain)
        let base64Query = query.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        // Send via HTTPS GET
        let urlString = "\(serverURL)?dns=\(base64Query)"
        guard let url = URL(string: urlString) else {
            throw DoHError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5

        let (data, _) = try await URLSession.shared.data(for: request)
        let ip = try Self.parseARecord(data)

        // Cache with 5 minute TTL
        lock.lock()
        cache[domain] = CacheEntry(ip: ip, expiry: Date().addingTimeInterval(300))
        lock.unlock()

        return ip
    }

    /// Build a DNS query packet for A record lookup
    static func buildDNSQuery(domain: String) -> Data {
        var query = Data()

        // Header
        let txID = UInt16.random(in: 0...0xFFFF)
        query.append(UInt8(txID >> 8))
        query.append(UInt8(txID & 0xFF))
        query.append(contentsOf: [0x01, 0x00]) // flags: standard query, recursion desired
        query.append(contentsOf: [0x00, 0x01]) // QDCOUNT=1
        query.append(contentsOf: [0x00, 0x00]) // ANCOUNT=0
        query.append(contentsOf: [0x00, 0x00]) // NSCOUNT=0
        query.append(contentsOf: [0x00, 0x00]) // ARCOUNT=0

        // Question: domain name
        for label in domain.split(separator: ".") {
            let bytes = Data(label.utf8)
            query.append(UInt8(bytes.count))
            query.append(contentsOf: bytes)
        }
        query.append(0x00) // root label

        query.append(contentsOf: [0x00, 0x01]) // QTYPE=A
        query.append(contentsOf: [0x00, 0x01]) // QCLASS=IN

        return query
    }

    /// Parse first A record from DNS response, return IPv4 string
    static func parseARecord(_ data: Data) throws -> String {
        guard data.count >= 12 else { throw DoHError.invalidResponse }

        // Skip header (12 bytes)
        var offset = 12

        // Skip question section
        let qdCount = Int(UInt16(data[4]) << 8 | UInt16(data[5]))
        for _ in 0..<qdCount {
            offset = try skipDNSName(data, offset: offset)
            offset += 4 // QTYPE + QCLASS
        }

        // Parse answer section
        let anCount = Int(UInt16(data[6]) << 8 | UInt16(data[7]))
        for _ in 0..<anCount {
            offset = try skipDNSName(data, offset: offset)
            guard offset + 10 <= data.count else { throw DoHError.invalidResponse }

            let rdType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let rdLength = Int(UInt16(data[offset + 8]) << 8 | UInt16(data[offset + 9]))
            offset += 10

            if rdType == 1 && rdLength == 4 {
                // A record
                guard offset + 4 <= data.count else { throw DoHError.invalidResponse }
                return "\(data[offset]).\(data[offset+1]).\(data[offset+2]).\(data[offset+3])"
            }

            offset += rdLength
        }

        throw DoHError.noARecord
    }

    /// Skip a DNS name (handles label compression pointers)
    private static func skipDNSName(_ data: Data, offset: Int) throws -> Int {
        var pos = offset
        while pos < data.count {
            let len = Int(data[pos])
            if len == 0 {
                return pos + 1
            } else if len & 0xC0 == 0xC0 {
                // Compression pointer (2 bytes)
                return pos + 2
            } else {
                pos += 1 + len
            }
        }
        throw DoHError.invalidResponse
    }
}

public enum DoHError: Error {
    case invalidURL
    case invalidResponse
    case noARecord
}
```

- [ ] **Step 4: 运行 DoH 测试**

Run: `cd shadowproxy/source && swift test --filter DoHResolverTests 2>&1 | tail -10`
Expected: 2 tests PASS

- [ ] **Step 5: 修改 Outbound.relayDirect() 使用 DoH**

在 `Outbound` 中新增 `dohResolver` 属性：

```swift
private let dohResolver: DoHResolver

// init 中初始化：
self.dohResolver = DoHResolver(server: config.general.dnsServer)
```

修改 `relayDirect()` — 对域名先 DoH 解析再用 IP 建连：

```swift
private func relayDirect(client: NWConnection, target: ProxyTarget, initialData: Data?) async throws {
    let host: String
    // 如果是域名（非 IP），先用 DoH 解析避免 DNS 泄漏
    if target.host.contains(".") && target.host.first?.isLetter == true {
        do {
            host = try await dohResolver.resolve(target.host)
            splog.debug("DoH resolved \(target.host) → \(host)", tag: "Outbound")
        } catch {
            splog.warning("DoH failed for \(target.host), falling back to system DNS: \(error)", tag: "Outbound")
            host = target.host
        }
    } else {
        host = target.host
    }

    let remote = NWConnection(
        host: NWEndpoint.Host(host),
        port: NWEndpoint.Port(rawValue: target.port)!,
        using: .tcp
    )
    try await remote.connectAsync(queue: queue)

    if let data = initialData {
        try await Relay.sendData(data, to: remote)
    }

    await Relay.bridge(client: client, remote: remote)
}
```

- [ ] **Step 6: 运行全量测试**

Run: `cd shadowproxy/source && swift test 2>&1 | tail -20`
Expected: 所有测试通过

- [ ] **Step 7: Commit**

```bash
git add Sources/ShadowProxyCore/Engine/DoHResolver.swift Sources/ShadowProxyCore/Engine/Outbound.swift Tests/ShadowProxyCoreTests/DoHResolverTests.swift
git commit -m "feat: DoH DNS 防泄漏，DIRECT 连接不走系统 DNS"
```

---

### Task 7: 集成验证 + VMess 默认 option 切换

**Files:**
- Modify: `Sources/ShadowProxyCore/Engine/Outbound.swift`
- Modify: `Sources/ShadowProxyCore/Engine/Relay.swift`

- [ ] **Step 1: 更新 Outbound.relayVMess 传入 option**

修改 `relayVMess()` 中 `VMessHeader.buildRequest` 调用，传入 `option: config.option`。

修改 `VMessDataCipher` 初始化，传入 `option: config.option`。

修改 `Relay.vmessBridge` 调用，确保 response 侧的 `VMessDataCipher` 也使用相同 option。

- [ ] **Step 2: 更新 Relay.vmessDecryptForward 支持 option**

`vmessBridge` 和 `vmessDecryptForward` 需要知道 option 来正确初始化 response 解密的 `VMessDataCipher`。

给 `vmessBridge` 添加 `option: VMessOption` 参数：

```swift
public static func vmessBridge(
    client: NWConnection,
    remote: NWConnection,
    encryptCipher: VMessDataCipher,
    responseKey: Data,
    responseIV: Data,
    option: VMessOption = .chunkStream
) async {
```

在 `vmessDecryptForward` 中初始化 `decryptCipher` 时使用 option：

```swift
decryptCipher = VMessDataCipher(key: responseKey, iv: responseIV, option: option)
```

- [ ] **Step 3: 运行全量测试**

Run: `cd shadowproxy/source && swift test 2>&1 | tail -20`
Expected: 所有测试通过

- [ ] **Step 4: 端到端手动测试**

1. 用现有 VMess 节点测试（保持 option=.chunkStream 确保向后兼容）
2. 如果有支持 0x1D 的服务端，切换 option 测试

Run: `cd shadowproxy/source && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/ShadowProxyCore/Engine/Outbound.swift Sources/ShadowProxyCore/Engine/Relay.swift
git commit -m "feat: VMess 默认切换到 0x1D padding，集成 option 传递"
```

---

## 实现顺序与依赖

```
Task 1 (TransportConfig + 配置解析)
  ↓
Task 2 (传输层连接工厂) ← 依赖 Task 1 的 TransportConfig
  ↓
Task 3 (VLESS) ← 依赖 Task 2 的 createConnection
Task 4 (Trojan) ← 依赖 Task 2，可与 Task 3 并行
  ↓
Task 5 (SHAKE-128 + VMess padding) ← 独立，可与 Task 3/4 并行
Task 6 (DoH DNS) ← 独立，可与 Task 3/4/5 并行
  ↓
Task 7 (集成验证) ← 依赖全部
```

**可并行组：**
- Task 3 + Task 4（两个协议独立）
- Task 5 + Task 6（SHAKE-128 和 DoH 互不依赖）

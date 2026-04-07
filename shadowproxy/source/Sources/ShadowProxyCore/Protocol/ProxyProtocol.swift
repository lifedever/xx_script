import Foundation
import Network

/// 代理目标地址
public struct ProxyTarget: Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// 代理服务器配置
public enum ServerConfig: Sendable {
    case shadowsocks(ShadowsocksConfig)
    case vmess(VMessConfig)
    case vless(VLESSConfig)
    case trojan(TrojanConfig)
    case direct
}

public struct TransportConfig: Sendable {
    public var tls: Bool
    public var tlsSNI: String?
    public var tlsALPN: [String]?
    public var tlsAllowInsecure: Bool
    public var wsPath: String?
    public var wsHost: String?

    public init(tls: Bool = false, tlsSNI: String? = nil, tlsALPN: [String]? = nil,
                tlsAllowInsecure: Bool = false, wsPath: String? = nil, wsHost: String? = nil) {
        self.tls = tls; self.tlsSNI = tlsSNI; self.tlsALPN = tlsALPN
        self.tlsAllowInsecure = tlsAllowInsecure; self.wsPath = wsPath; self.wsHost = wsHost
    }
}

public struct ShadowsocksConfig: Sendable {
    public let server: String
    public let port: UInt16
    public let method: String
    public let password: String
    public let obfsPlugin: String?
    public let obfsHost: String?
    public let transport: TransportConfig

    public init(server: String, port: UInt16, method: String, password: String, obfsPlugin: String? = nil, obfsHost: String? = nil, transport: TransportConfig = TransportConfig()) {
        self.server = server
        self.port = port
        self.method = method
        self.password = password
        self.obfsPlugin = obfsPlugin
        self.obfsHost = obfsHost
        self.transport = transport
    }
}

/// VMess data channel option (controls chunk format on wire)
public enum VMessOption: UInt8, Sendable {
    /// Plain 2-byte length + GCM payload
    case chunkStream = 0x01
    /// SHAKE-128 masked length (GCM encrypted) + GCM payload
    case chunkMasking = 0x05
    /// SHAKE-128 masked length (GCM encrypted) + GCM payload + random padding
    case chunkMaskingPadding = 0x1D
}

public struct VMessConfig: Sendable {
    public let server: String
    public let port: UInt16
    public let uuid: String
    public let alterId: Int
    public let security: String
    public let option: VMessOption
    public let transport: TransportConfig

    public init(server: String, port: UInt16, uuid: String, alterId: Int = 0, security: String = "auto", option: VMessOption = .chunkMaskingPadding, transport: TransportConfig = TransportConfig()) {
        self.server = server
        self.port = port
        self.uuid = uuid
        self.alterId = alterId
        self.security = security
        self.option = option
        self.transport = transport
    }
}

public struct VLESSConfig: Sendable {
    public let server: String
    public let port: UInt16
    public let uuid: String
    public let transport: TransportConfig

    public init(server: String, port: UInt16, uuid: String, transport: TransportConfig = TransportConfig()) {
        self.server = server; self.port = port; self.uuid = uuid; self.transport = transport
    }
}

public struct TrojanConfig: Sendable {
    public let server: String
    public let port: UInt16
    public let password: String
    public let transport: TransportConfig

    public init(server: String, port: UInt16, password: String, transport: TransportConfig = TransportConfig(tls: true)) {
        self.server = server; self.port = port; self.password = password
        var t = transport; t.tls = true; self.transport = t
    }
}

/// 所有代理协议实现这个接口
public protocol ProxyProtocol: Sendable {
    var name: String { get }
    func connect(to target: ProxyTarget, via server: ServerConfig) async throws -> ProxySession
}

/// 代理会话
public protocol ProxySession: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

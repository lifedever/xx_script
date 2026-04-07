import Foundation
import Network
import CryptoKit

/// Outbound handles creating proxy connections and relaying data
public final class Outbound: @unchecked Sendable {
    private let proxies: [String: ServerConfig]
    private let groups: [String: ProxyGroup]
    private let queue = DispatchQueue(label: "shadowproxy.outbound")

    /// Currently selected node per group (group name -> node name)
    private var selectedNodes: [String: String] = [:]

    public init(proxies: [String: ServerConfig], groups: [ProxyGroup]) {
        self.proxies = proxies
        var groupMap: [String: ProxyGroup] = [:]
        for g in groups { groupMap[g.name] = g }
        self.groups = groupMap

        // Default selection: first member of each group
        for g in groups {
            if let first = g.members.first {
                selectedNodes[g.name] = first
            }
        }
    }

    public func select(group: String, node: String) {
        selectedNodes[group] = node
    }

    public func getSelectedNodes() -> [String: String] {
        selectedNodes
    }

    /// Resolve a policy name to a concrete ServerConfig
    /// Handles group references (e.g., "🤖OpenAI" → "Proxy" → "🇯🇵 日本")
    public func resolvePolicy(_ policy: String) -> ServerConfig? {
        // Direct proxy name?
        if let config = proxies[policy] { return config }

        // DIRECT
        if policy.uppercased() == "DIRECT" { return .direct }

        // Group reference → resolve selected node
        if let selected = selectedNodes[policy] {
            return resolvePolicy(selected) // Recursive for nested groups
        }

        return nil
    }

    /// Create a connection to the proxy server and relay data with the client
    public func relay(
        client: NWConnection,
        target: ProxyTarget,
        policy: String,
        initialData: Data? = nil
    ) {
        guard let serverConfig = resolvePolicy(policy) else {
            splog.warning("Cannot resolve policy: \(policy)", tag: "Outbound")
            client.cancel()
            return
        }

        Task {
            do {
                switch serverConfig {
                case .direct:
                    splog.debug("DIRECT → \(target.host):\(target.port)", tag: "Outbound")
                    try await relayDirect(client: client, target: target, initialData: initialData)
                case .shadowsocks(let config):
                    splog.debug("SS → \(config.server):\(config.port) → \(target.host):\(target.port)", tag: "Outbound")
                    try await relayShadowsocks(client: client, target: target, config: config, initialData: initialData)
                case .vmess(let config):
                    splog.debug("VMess → \(config.server):\(config.port) → \(target.host):\(target.port)", tag: "Outbound")
                    try await relayVMess(client: client, target: target, config: config, initialData: initialData)
                case .vless:
                    splog.warning("VLESS not yet implemented", tag: "Outbound")
                    client.cancel()
                case .trojan:
                    splog.warning("Trojan not yet implemented", tag: "Outbound")
                    client.cancel()
                }
            } catch {
                splog.error("Relay error for \(target.host): \(error)", tag: "Outbound")
                client.cancel()
            }
        }
    }

    // MARK: - Direct

    private func relayDirect(client: NWConnection, target: ProxyTarget, initialData: Data?) async throws {
        let remote = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: .tcp
        )
        try await remote.connectAsync(queue: queue)

        if let data = initialData {
            try await Relay.sendData(data, to: remote)
        }

        await Relay.bridge(client: client, remote: remote)
    }

    // MARK: - Shadowsocks

    private func relayShadowsocks(client: NWConnection, target: ProxyTarget, config: ShadowsocksConfig, initialData: Data?) async throws {
        let keyLen = keyLength(for: config.method)
        let masterKey = ShadowsocksKeyDerivation.evpBytesToKey(password: config.password, keyLen: keyLen)

        // Connect to SS server
        let remote = NWConnection(
            host: NWEndpoint.Host(config.server),
            port: NWEndpoint.Port(rawValue: config.port)!,
            using: .tcp
        )
        try await remote.connectAsync(queue: queue)
        splog.debug("SS connected to \(config.server):\(config.port)", tag: "SS")

        // Generate salt
        let salt = Data((0..<keyLen).map { _ in UInt8.random(in: 0...255) })
        let subkey = ShadowsocksKeyDerivation.hkdfSHA1(key: masterKey, salt: salt, keyLen: keyLen)

        // Build target address header
        var addrHeader = Data()
        addrHeader.append(0x03) // Domain type
        let domainBytes = Data(target.host.utf8)
        addrHeader.append(UInt8(domainBytes.count))
        addrHeader.append(domainBytes)
        addrHeader.append(UInt8(target.port >> 8))
        addrHeader.append(UInt8(target.port & 0xFF))

        // Encrypt address header as first payload
        var cipher = AESGCMCipher(key: SymmetricKey(data: subkey))

        // Length chunk
        let addrLen = UInt16(addrHeader.count)
        var lenData = Data()
        lenData.append(UInt8(addrLen >> 8))
        lenData.append(UInt8(addrLen & 0xFF))
        let encLen = try cipher.encrypt(lenData)

        // Payload chunk
        let encPayload = try cipher.encrypt(addrHeader)

        // Build initial send: [salt][enc_len][enc_payload]
        var initialSend = salt
        initialSend.append(encLen)
        initialSend.append(encPayload)

        // If using obfs-http, wrap in HTTP
        if config.obfsPlugin != nil, let obfsHost = config.obfsHost {
            let obfs = ObfsHTTP(host: obfsHost)
            let wrapped = obfs.wrapRequest(initialSend)
            let headerEnd = wrapped.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))?.lowerBound ?? wrapped.endIndex
            let headerStr = String(data: wrapped.prefix(upTo: headerEnd), encoding: .utf8) ?? ""
            splog.debug("SS obfs request (\(wrapped.count)b), payload=\(initialSend.count), headers: \(headerStr.replacingOccurrences(of: "\r\n", with: " | "))", tag: "SS")
            try await Relay.sendData(wrapped, to: remote)
        } else {
            try await Relay.sendData(initialSend, to: remote)
        }

        // If there's initial data from plain HTTP request, encrypt and send it too
        if let data = initialData {
            let dataLen = UInt16(data.count)
            var dl = Data()
            dl.append(UInt8(dataLen >> 8))
            dl.append(UInt8(dataLen & 0xFF))
            let encDL = try cipher.encrypt(dl)
            let encData = try cipher.encrypt(data)
            var chunk = encDL
            chunk.append(encData)
            try await Relay.sendData(chunk, to: remote)
        }

        splog.debug("SS handshake sent, starting AEAD relay for \(target.host)", tag: "SS")

        // Bidirectional AEAD relay: encrypt client→remote, decrypt remote→client
        await Relay.shadowsocksBridge(
            client: client,
            remote: remote,
            encryptCipher: cipher,
            masterKey: masterKey,
            keyLen: keyLen,
            obfsHost: config.obfsHost
        )
    }

    // MARK: - VMess

    private func relayVMess(client: NWConnection, target: ProxyTarget, config: VMessConfig, initialData: Data?) async throws {
        let remote = NWConnection(
            host: NWEndpoint.Host(config.server),
            port: NWEndpoint.Port(rawValue: config.port)!,
            using: .tcp
        )
        try await remote.connectAsync(queue: queue)
        splog.debug("VMess connected to \(config.server):\(config.port)", tag: "VMess")

        let reqKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let reqIV = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        let security: VMessSecurity = config.security == "chacha20-poly1305" ? .chacha20poly1305 : .aes128gcm

        let (header, responseKey, responseIV) = try VMessHeader.buildRequest(
            uuid: config.uuid,
            target: target,
            security: security,
            reqKey: reqKey,
            reqIV: reqIV
        )

        // Send VMess header
        try await Relay.sendData(header, to: remote)

        // Encryption cipher for client→remote data
        var encCipher = VMessDataCipher(key: reqKey, iv: reqIV)

        // If there's initial data, encrypt and send
        if let data = initialData {
            let chunk = try encCipher.encrypt(data)
            try await Relay.sendData(chunk, to: remote)
        }

        splog.debug("VMess handshake sent, starting AEAD relay for \(target.host)", tag: "VMess")

        // Bidirectional AEAD relay
        await Relay.vmessBridge(
            client: client,
            remote: remote,
            encryptCipher: encCipher,
            responseKey: responseKey,
            responseIV: responseIV
        )
    }

    // MARK: - Helpers

    private func keyLength(for method: String) -> Int {
        switch method.lowercased() {
        case "aes-128-gcm": return 16
        case "aes-256-gcm": return 32
        case "chacha20-ietf-poly1305": return 32
        default: return 16
        }
    }
}

import Foundation

// MARK: - Types

public struct ParsedNode: Sendable {
    public let name: String
    public let serverConfig: ServerConfig
}

public enum SubscriptionError: Error, Sendable {
    case unsupportedProtocol
    case invalidFormat
    case fetchFailed
}

// MARK: - Parser

public struct SubscriptionParser {

    // MARK: Public

    /// Parse a single proxy URI (ss://, vmess://, vless://, trojan://)
    public static func parseURI(_ uri: String) throws -> ParsedNode {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ss://") {
            return try parseSS(trimmed)
        } else if trimmed.hasPrefix("vmess://") {
            return try parseVMess(trimmed)
        } else if trimmed.hasPrefix("vless://") {
            return try parseVLESS(trimmed)
        } else if trimmed.hasPrefix("trojan://") {
            return try parseTrojan(trimmed)
        }
        throw SubscriptionError.unsupportedProtocol
    }

    /// Parse a subscription response (base64-encoded list of URIs, or plain text)
    public static func parseSubscription(_ content: String) throws -> [ParsedNode] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try base64 decode first
        let lines: [String]
        if let data = Data(base64Encoded: trimmed),
           let decoded = String(data: data, encoding: .utf8) {
            lines = decoded.components(separatedBy: .newlines)
        } else {
            lines = trimmed.components(separatedBy: .newlines)
        }

        var nodes: [ParsedNode] = []
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !l.isEmpty else { continue }
            if let node = try? parseURI(l) {
                nodes.append(node)
            }
        }
        return nodes
    }

    // MARK: - SS

    private static func parseSS(_ uri: String) throws -> ParsedNode {
        // ss://base64(method:password)@server:port#name
        let body = String(uri.dropFirst("ss://".count))

        // Split fragment (name)
        let (main, fragment) = splitFragment(body)

        // Split userinfo@host:port
        guard let atIndex = main.lastIndex(of: "@") else { throw SubscriptionError.invalidFormat }
        let userInfo = String(main[main.startIndex..<atIndex])
        let hostPort = String(main[main.index(after: atIndex)...])

        // Decode userinfo (base64 -> method:password)
        guard let decoded = base64Decode(userInfo) else { throw SubscriptionError.invalidFormat }
        let parts = decoded.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { throw SubscriptionError.invalidFormat }
        let method = String(parts[0])
        let password = String(parts[1])

        // Parse host:port
        let (host, port) = try parseHostPort(hostPort)
        let name = fragment.flatMap { $0.removingPercentEncoding } ?? host

        let config = ShadowsocksConfig(server: host, port: port, method: method, password: password)
        return ParsedNode(name: name, serverConfig: .shadowsocks(config))
    }

    // MARK: - VMess

    private static func parseVMess(_ uri: String) throws -> ParsedNode {
        // vmess://base64(json)
        let body = String(uri.dropFirst("vmess://".count))
        guard let data = Data(base64Encoded: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubscriptionError.invalidFormat
        }

        guard let server = json["add"] as? String,
              let portStr = json["port"] as? String,
              let port = UInt16(portStr),
              let uuid = json["id"] as? String else {
            throw SubscriptionError.invalidFormat
        }

        let name = json["ps"] as? String ?? server
        let alterId = Int(json["aid"] as? String ?? "0") ?? 0
        let net = json["net"] as? String ?? ""
        let tlsStr = json["tls"] as? String ?? ""
        let sni = json["sni"] as? String
        let path = json["path"] as? String

        let transport = TransportConfig(
            tls: tlsStr == "tls",
            tlsSNI: sni,
            wsPath: net == "ws" ? path : nil,
            wsHost: sni
        )

        let config = VMessConfig(server: server, port: port, uuid: uuid, alterId: alterId, transport: transport)
        return ParsedNode(name: name, serverConfig: .vmess(config))
    }

    // MARK: - VLESS

    private static func parseVLESS(_ uri: String) throws -> ParsedNode {
        // vless://uuid@server:port?params#name
        let body = String(uri.dropFirst("vless://".count))
        let (main, fragment) = splitFragment(body)

        // Split query
        let (pathPart, queryParams) = splitQuery(main)

        guard let atIndex = pathPart.lastIndex(of: "@") else { throw SubscriptionError.invalidFormat }
        let uuid = String(pathPart[pathPart.startIndex..<atIndex])
        let hostPort = String(pathPart[pathPart.index(after: atIndex)...])
        let (host, port) = try parseHostPort(hostPort)

        let security = queryParams["security"] ?? ""
        let sni = queryParams["sni"]
        let netType = queryParams["type"] ?? ""
        let path = queryParams["path"]?.removingPercentEncoding

        let transport = TransportConfig(
            tls: security == "tls" || security == "reality",
            tlsSNI: sni,
            wsPath: netType == "ws" ? path : nil,
            wsHost: sni
        )

        let name = fragment.flatMap { $0.removingPercentEncoding } ?? host
        let config = VLESSConfig(server: host, port: port, uuid: uuid, transport: transport)
        return ParsedNode(name: name, serverConfig: .vless(config))
    }

    // MARK: - Trojan

    private static func parseTrojan(_ uri: String) throws -> ParsedNode {
        // trojan://password@server:port?params#name
        let body = String(uri.dropFirst("trojan://".count))
        let (main, fragment) = splitFragment(body)
        let (pathPart, queryParams) = splitQuery(main)

        guard let atIndex = pathPart.lastIndex(of: "@") else { throw SubscriptionError.invalidFormat }
        let password = String(pathPart[pathPart.startIndex..<atIndex])
        let hostPort = String(pathPart[pathPart.index(after: atIndex)...])
        let (host, port) = try parseHostPort(hostPort)

        let sni = queryParams["sni"]
        let netType = queryParams["type"] ?? ""
        let path = queryParams["path"]?.removingPercentEncoding

        // Trojan always forces TLS
        let transport = TransportConfig(
            tls: true,
            tlsSNI: sni,
            wsPath: netType == "ws" ? path : nil,
            wsHost: sni
        )

        let name = fragment.flatMap { $0.removingPercentEncoding } ?? host
        let config = TrojanConfig(server: host, port: port, password: password, transport: transport)
        return ParsedNode(name: name, serverConfig: .trojan(config))
    }

    // MARK: - Helpers

    private static func splitFragment(_ s: String) -> (String, String?) {
        if let idx = s.firstIndex(of: "#") {
            return (String(s[s.startIndex..<idx]), String(s[s.index(after: idx)...]))
        }
        return (s, nil)
    }

    private static func splitQuery(_ s: String) -> (String, [String: String]) {
        guard let idx = s.firstIndex(of: "?") else { return (s, [:]) }
        let path = String(s[s.startIndex..<idx])
        let queryString = String(s[s.index(after: idx)...])
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                params[String(kv[0])] = String(kv[1])
            }
        }
        return (path, params)
    }

    private static func parseHostPort(_ s: String) throws -> (String, UInt16) {
        // Handle IPv6: [::1]:port
        if s.hasPrefix("[") {
            guard let closeBracket = s.firstIndex(of: "]") else { throw SubscriptionError.invalidFormat }
            let host = String(s[s.index(after: s.startIndex)..<closeBracket])
            let afterBracket = s.index(after: closeBracket)
            guard afterBracket < s.endIndex, s[afterBracket] == ":" else { throw SubscriptionError.invalidFormat }
            let portStr = String(s[s.index(after: afterBracket)...])
            guard let port = UInt16(portStr) else { throw SubscriptionError.invalidFormat }
            return (host, port)
        }

        guard let colonIdx = s.lastIndex(of: ":") else { throw SubscriptionError.invalidFormat }
        let host = String(s[s.startIndex..<colonIdx])
        let portStr = String(s[s.index(after: colonIdx)...])
        guard let port = UInt16(portStr) else { throw SubscriptionError.invalidFormat }
        return (host, port)
    }

    private static func base64Decode(_ s: String) -> String? {
        // Handle URL-safe base64 and missing padding
        var base64 = s.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

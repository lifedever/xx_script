// BoxX/Models/ParsedProxy.swift
import Foundation

enum ProxyType: String, Codable, Sendable {
    case vmess, shadowsocks, trojan, hysteria2, vless
}

struct ParsedProxy: Sendable {
    let tag: String
    let type: ProxyType
    let server: String
    let port: Int
    let rawJSON: JSONValue

    /// Convert to Outbound for storage in proxies/*.json
    func toOutbound() -> Outbound {
        do {
            let data = try JSONEncoder().encode(rawJSON)
            return try JSONDecoder().decode(Outbound.self, from: data)
        } catch {
            return .unknown(tag: tag, type: type.rawValue, raw: rawJSON)
        }
    }
}

protocol ProxyParser: Sendable {
    func canParse(_ data: Data) -> Bool
    func parse(_ data: Data) throws -> [ParsedProxy]
}

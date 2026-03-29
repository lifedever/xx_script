// BoxX/Services/SingBoxJSONParser.swift
import Foundation

struct SingBoxJSONParser: ProxyParser {
    func canParse(_ data: Data) -> Bool {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        switch json {
        case .object(let dict):
            return dict["outbounds"] != nil
        case .array(let arr):
            if let first = arr.first, case .object(let dict) = first {
                return dict["type"] != nil
            }
            return false
        default:
            return false
        }
    }

    func parse(_ data: Data) throws -> [ParsedProxy] {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)

        let outboundValues: [JSONValue]
        switch json {
        case .object(let dict):
            guard let outbounds = dict["outbounds"]?.arrayValue else {
                throw ParserError.invalidFormat("Missing 'outbounds' array")
            }
            outboundValues = outbounds
        case .array(let arr):
            outboundValues = arr
        default:
            throw ParserError.invalidFormat("Expected object or array")
        }

        let proxyTypes: Set<String> = ["vmess", "shadowsocks", "trojan", "hysteria2", "vless"]

        return outboundValues.compactMap { value -> ParsedProxy? in
            guard case .object(let dict) = value,
                  let typeStr = dict["type"]?.stringValue,
                  proxyTypes.contains(typeStr),
                  let tag = dict["tag"]?.stringValue,
                  let server = dict["server"]?.stringValue,
                  let port = dict["server_port"]?.numberValue,
                  let proxyType = ProxyType(rawValue: typeStr) else {
                return nil
            }
            return ParsedProxy(
                tag: tag,
                type: proxyType,
                server: server,
                port: Int(port),
                rawJSON: value
            )
        }
    }
}

enum ParserError: Error, LocalizedError {
    case invalidFormat(String)
    case unsupportedProtocol(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "Invalid format: \(msg)"
        case .unsupportedProtocol(let proto): return "Unsupported protocol: \(proto)"
        }
    }
}

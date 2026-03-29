// BoxX/Models/OutboundConfig.swift
import Foundation

// MARK: - Dynamic Coding Key

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - DirectOutbound

struct DirectOutbound: Codable, Equatable, Sendable {
    var tag: String
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tag
    }

    init(tag: String) {
        self.tag = tag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)

        let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue != "type" && !knownKeys.contains(key.stringValue) {
                unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
            }
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - SelectorOutbound

struct SelectorOutbound: Codable, Equatable, Sendable {
    var tag: String
    var outbounds: [String]
    var `default`: String?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tag, outbounds, `default`
    }

    init(tag: String, outbounds: [String], default defaultOutbound: String? = nil) {
        self.tag = tag
        self.outbounds = outbounds
        self.default = defaultOutbound
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        outbounds = try container.decode([String].self, forKey: .outbounds)
        `default` = try container.decodeIfPresent(String.self, forKey: .default)

        let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue != "type" && !knownKeys.contains(key.stringValue) {
                unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
            }
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(outbounds, forKey: .outbounds)
        try container.encodeIfPresent(`default`, forKey: .default)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - URLTestOutbound

struct URLTestOutbound: Codable, Equatable, Sendable {
    var tag: String
    var outbounds: [String]
    var url: String?
    var interval: String?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tag, outbounds, url, interval
    }

    init(tag: String, outbounds: [String], url: String? = nil, interval: String? = nil) {
        self.tag = tag
        self.outbounds = outbounds
        self.url = url
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        outbounds = try container.decode([String].self, forKey: .outbounds)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        interval = try container.decodeIfPresent(String.self, forKey: .interval)

        let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue != "type" && !knownKeys.contains(key.stringValue) {
                unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
            }
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(outbounds, forKey: .outbounds)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(interval, forKey: .interval)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - VMessOutbound

struct VMessOutbound: Codable, Equatable, Sendable {
    var tag: String
    var server: String
    var serverPort: Int
    var uuid: String
    var alterId: Int?
    var security: String?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tag, server, uuid, security
        case serverPort = "server_port"
        case alterId = "alter_id"
    }

    init(tag: String, server: String, serverPort: Int, uuid: String, alterId: Int? = nil, security: String? = nil) {
        self.tag = tag
        self.server = server
        self.serverPort = serverPort
        self.uuid = uuid
        self.alterId = alterId
        self.security = security
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        server = try container.decode(String.self, forKey: .server)
        serverPort = try container.decode(Int.self, forKey: .serverPort)
        uuid = try container.decode(String.self, forKey: .uuid)
        alterId = try container.decodeIfPresent(Int.self, forKey: .alterId)
        security = try container.decodeIfPresent(String.self, forKey: .security)

        let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue != "type" && !knownKeys.contains(key.stringValue) {
                unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
            }
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(server, forKey: .server)
        try container.encode(serverPort, forKey: .serverPort)
        try container.encode(uuid, forKey: .uuid)
        try container.encodeIfPresent(alterId, forKey: .alterId)
        try container.encodeIfPresent(security, forKey: .security)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - ShadowsocksOutbound

struct ShadowsocksOutbound: Codable, Equatable, Sendable {
    var tag: String
    var server: String
    var serverPort: Int
    var method: String
    var password: String
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tag, server, method, password
        case serverPort = "server_port"
    }

    init(tag: String, server: String, serverPort: Int, method: String, password: String) {
        self.tag = tag
        self.server = server
        self.serverPort = serverPort
        self.method = method
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        server = try container.decode(String.self, forKey: .server)
        serverPort = try container.decode(Int.self, forKey: .serverPort)
        method = try container.decode(String.self, forKey: .method)
        password = try container.decode(String.self, forKey: .password)

        let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue != "type" && !knownKeys.contains(key.stringValue) {
                unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
            }
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(server, forKey: .server)
        try container.encode(serverPort, forKey: .serverPort)
        try container.encode(method, forKey: .method)
        try container.encode(password, forKey: .password)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - TrojanOutbound

struct TrojanOutbound: Codable, Equatable, Sendable {
    var tag: String
    var server: String
    var serverPort: Int
    var password: String
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tag, server, password
        case serverPort = "server_port"
    }

    init(tag: String, server: String, serverPort: Int, password: String) {
        self.tag = tag
        self.server = server
        self.serverPort = serverPort
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        server = try container.decode(String.self, forKey: .server)
        serverPort = try container.decode(Int.self, forKey: .serverPort)
        password = try container.decode(String.self, forKey: .password)

        let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue != "type" && !knownKeys.contains(key.stringValue) {
                unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
            }
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(server, forKey: .server)
        try container.encode(serverPort, forKey: .serverPort)
        try container.encode(password, forKey: .password)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - Hysteria2Outbound

struct Hysteria2Outbound: Codable, Equatable, Sendable {
    var tag: String
    var server: String
    var serverPort: Int
    var password: String
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tag, server, password
        case serverPort = "server_port"
    }

    init(tag: String, server: String, serverPort: Int, password: String) {
        self.tag = tag
        self.server = server
        self.serverPort = serverPort
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        server = try container.decode(String.self, forKey: .server)
        serverPort = try container.decode(Int.self, forKey: .serverPort)
        password = try container.decode(String.self, forKey: .password)

        let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue != "type" && !knownKeys.contains(key.stringValue) {
                unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
            }
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(server, forKey: .server)
        try container.encode(serverPort, forKey: .serverPort)
        try container.encode(password, forKey: .password)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - VLESSOutbound

struct VLESSOutbound: Codable, Equatable, Sendable {
    var tag: String
    var server: String
    var serverPort: Int
    var uuid: String
    var flow: String?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tag, server, uuid, flow
        case serverPort = "server_port"
    }

    init(tag: String, server: String, serverPort: Int, uuid: String, flow: String? = nil) {
        self.tag = tag
        self.server = server
        self.serverPort = serverPort
        self.uuid = uuid
        self.flow = flow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        server = try container.decode(String.self, forKey: .server)
        serverPort = try container.decode(Int.self, forKey: .serverPort)
        uuid = try container.decode(String.self, forKey: .uuid)
        flow = try container.decodeIfPresent(String.self, forKey: .flow)

        let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue != "type" && !knownKeys.contains(key.stringValue) {
                unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
            }
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(server, forKey: .server)
        try container.encode(serverPort, forKey: .serverPort)
        try container.encode(uuid, forKey: .uuid)
        try container.encodeIfPresent(flow, forKey: .flow)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - Outbound Enum

enum Outbound: Codable, Equatable, Sendable {
    case direct(DirectOutbound)
    case selector(SelectorOutbound)
    case urltest(URLTestOutbound)
    case vmess(VMessOutbound)
    case shadowsocks(ShadowsocksOutbound)
    case trojan(TrojanOutbound)
    case hysteria2(Hysteria2Outbound)
    case vless(VLESSOutbound)
    case unknown(tag: String, type: String, raw: JSONValue)

    var tag: String {
        switch self {
        case .direct(let o): o.tag
        case .selector(let o): o.tag
        case .urltest(let o): o.tag
        case .vmess(let o): o.tag
        case .shadowsocks(let o): o.tag
        case .trojan(let o): o.tag
        case .hysteria2(let o): o.tag
        case .vless(let o): o.tag
        case .unknown(let tag, _, _): tag
        }
    }

    private enum TypeCodingKeys: String, CodingKey {
        case type, tag
    }

    init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TypeCodingKeys.self)
        let type = try typeContainer.decode(String.self, forKey: .type)

        switch type {
        case "direct":
            self = .direct(try DirectOutbound(from: decoder))
        case "selector":
            self = .selector(try SelectorOutbound(from: decoder))
        case "urltest":
            self = .urltest(try URLTestOutbound(from: decoder))
        case "vmess":
            self = .vmess(try VMessOutbound(from: decoder))
        case "shadowsocks":
            self = .shadowsocks(try ShadowsocksOutbound(from: decoder))
        case "trojan":
            self = .trojan(try TrojanOutbound(from: decoder))
        case "hysteria2":
            self = .hysteria2(try Hysteria2Outbound(from: decoder))
        case "vless":
            self = .vless(try VLESSOutbound(from: decoder))
        default:
            let tag = try typeContainer.decode(String.self, forKey: .tag)
            let raw = try JSONValue(from: decoder)
            self = .unknown(tag: tag, type: type, raw: raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var typeContainer = encoder.container(keyedBy: TypeCodingKeys.self)

        switch self {
        case .direct(let o):
            try typeContainer.encode("direct", forKey: .type)
            try o.encode(to: encoder)
        case .selector(let o):
            try typeContainer.encode("selector", forKey: .type)
            try o.encode(to: encoder)
        case .urltest(let o):
            try typeContainer.encode("urltest", forKey: .type)
            try o.encode(to: encoder)
        case .vmess(let o):
            try typeContainer.encode("vmess", forKey: .type)
            try o.encode(to: encoder)
        case .shadowsocks(let o):
            try typeContainer.encode("shadowsocks", forKey: .type)
            try o.encode(to: encoder)
        case .trojan(let o):
            try typeContainer.encode("trojan", forKey: .type)
            try o.encode(to: encoder)
        case .hysteria2(let o):
            try typeContainer.encode("hysteria2", forKey: .type)
            try o.encode(to: encoder)
        case .vless(let o):
            try typeContainer.encode("vless", forKey: .type)
            try o.encode(to: encoder)
        case .unknown(_, _, let raw):
            try raw.encode(to: encoder)
        }
    }
}

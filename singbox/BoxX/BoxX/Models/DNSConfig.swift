// BoxX/Models/DNSConfig.swift
import Foundation

struct DNSConfig: Codable, Equatable, Sendable {
    var servers: [JSONValue]?
    var rules: [JSONValue]?
    var final_: String?
    var strategy: String?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case servers, rules, strategy
        case final_ = "final"
    }

    init(servers: [JSONValue]? = nil, rules: [JSONValue]? = nil, final_: String? = nil, strategy: String? = nil) {
        self.servers = servers
        self.rules = rules
        self.final_ = final_
        self.strategy = strategy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decodeIfPresent([JSONValue].self, forKey: .servers)
        rules = try container.decodeIfPresent([JSONValue].self, forKey: .rules)
        final_ = try container.decodeIfPresent(String.self, forKey: .final_)
        strategy = try container.decodeIfPresent(String.self, forKey: .strategy)

        let knownKeys = Set(CodingKeys.allCases.map { $0.rawValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys where !knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(servers, forKey: .servers)
        try container.encodeIfPresent(rules, forKey: .rules)
        try container.encodeIfPresent(final_, forKey: .final_)
        try container.encodeIfPresent(strategy, forKey: .strategy)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

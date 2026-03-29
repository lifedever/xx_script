// BoxX/Models/RouteConfig.swift
import Foundation

struct RouteConfig: Codable, Equatable, Sendable {
    var rules: [JSONValue]?
    var ruleSet: [JSONValue]?
    var final_: String?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rules
        case ruleSet = "rule_set"
        case final_ = "final"
    }

    init(rules: [JSONValue]? = nil, ruleSet: [JSONValue]? = nil, final_: String? = nil) {
        self.rules = rules
        self.ruleSet = ruleSet
        self.final_ = final_
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([JSONValue].self, forKey: .rules)
        ruleSet = try container.decodeIfPresent([JSONValue].self, forKey: .ruleSet)
        final_ = try container.decodeIfPresent(String.self, forKey: .final_)

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
        try container.encodeIfPresent(rules, forKey: .rules)
        try container.encodeIfPresent(ruleSet, forKey: .ruleSet)
        try container.encodeIfPresent(final_, forKey: .final_)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

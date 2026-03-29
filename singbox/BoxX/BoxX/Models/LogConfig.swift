// BoxX/Models/LogConfig.swift
import Foundation

struct LogConfig: Codable, Equatable, Sendable {
    var level: String?
    var timestamp: Bool?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case level, timestamp
    }

    init(level: String? = nil, timestamp: Bool? = nil) {
        self.level = level
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decodeIfPresent(String.self, forKey: .level)
        timestamp = try container.decodeIfPresent(Bool.self, forKey: .timestamp)

        let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys where !knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(level, forKey: .level)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

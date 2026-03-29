// BoxX/Models/ExperimentalConfig.swift
import Foundation

// MARK: - ClashApiConfig

struct ClashApiConfig: Codable, Equatable, Sendable {
    var externalController: String?
    var secret: String?
    var defaultMode: String?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case externalController = "external_controller"
        case secret
        case defaultMode = "default_mode"
    }

    init(externalController: String? = nil, secret: String? = nil, defaultMode: String? = nil) {
        self.externalController = externalController
        self.secret = secret
        self.defaultMode = defaultMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        externalController = try container.decodeIfPresent(String.self, forKey: .externalController)
        secret = try container.decodeIfPresent(String.self, forKey: .secret)
        defaultMode = try container.decodeIfPresent(String.self, forKey: .defaultMode)

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
        try container.encodeIfPresent(externalController, forKey: .externalController)
        try container.encodeIfPresent(secret, forKey: .secret)
        try container.encodeIfPresent(defaultMode, forKey: .defaultMode)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - ExperimentalConfig

struct ExperimentalConfig: Codable, Equatable, Sendable {
    var cacheFile: JSONValue?
    var clashApi: ClashApiConfig?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cacheFile = "cache_file"
        case clashApi = "clash_api"
    }

    init(cacheFile: JSONValue? = nil, clashApi: ClashApiConfig? = nil) {
        self.cacheFile = cacheFile
        self.clashApi = clashApi
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheFile = try container.decodeIfPresent(JSONValue.self, forKey: .cacheFile)
        clashApi = try container.decodeIfPresent(ClashApiConfig.self, forKey: .clashApi)

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
        try container.encodeIfPresent(cacheFile, forKey: .cacheFile)
        try container.encodeIfPresent(clashApi, forKey: .clashApi)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

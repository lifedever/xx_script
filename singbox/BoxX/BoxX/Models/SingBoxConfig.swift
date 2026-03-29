// BoxX/Models/SingBoxConfig.swift
import Foundation

// MARK: - Shared DynamicCodingKey

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - SingBoxConfig

struct SingBoxConfig: Codable, Equatable, Sendable {
    var log: LogConfig?
    var dns: DNSConfig?
    var inbounds: [JSONValue]
    var outbounds: [Outbound]
    var route: RouteConfig
    var experimental: ExperimentalConfig?
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case log, dns, inbounds, outbounds, route, experimental
    }

    init(
        log: LogConfig? = nil,
        dns: DNSConfig? = nil,
        inbounds: [JSONValue] = [],
        outbounds: [Outbound] = [],
        route: RouteConfig = RouteConfig(),
        experimental: ExperimentalConfig? = nil
    ) {
        self.log = log
        self.dns = dns
        self.inbounds = inbounds
        self.outbounds = outbounds
        self.route = route
        self.experimental = experimental
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        log = try container.decodeIfPresent(LogConfig.self, forKey: .log)
        dns = try container.decodeIfPresent(DNSConfig.self, forKey: .dns)
        inbounds = try container.decodeIfPresent([JSONValue].self, forKey: .inbounds) ?? []
        outbounds = try container.decodeIfPresent([Outbound].self, forKey: .outbounds) ?? []
        route = try container.decode(RouteConfig.self, forKey: .route)
        experimental = try container.decodeIfPresent(ExperimentalConfig.self, forKey: .experimental)

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
        try container.encodeIfPresent(log, forKey: .log)
        try container.encodeIfPresent(dns, forKey: .dns)
        try container.encode(inbounds, forKey: .inbounds)
        try container.encode(outbounds, forKey: .outbounds)
        try container.encode(route, forKey: .route)
        try container.encodeIfPresent(experimental, forKey: .experimental)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in unknownFields {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

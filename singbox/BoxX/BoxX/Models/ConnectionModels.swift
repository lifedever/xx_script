import Foundation

struct Connection: Identifiable, Codable, Sendable {
    let id: String
    let chains: [String]
    let download: Int64
    let upload: Int64
    let metadata: ConnectionMetadata
    let rule: String
    let rulePayload: String
    let start: String

    var host: String { metadata.host.isEmpty ? metadata.destinationIP : metadata.host }
    var outbound: String { chains.first ?? "" }
    var chain: String { chains.joined(separator: " -> ") }
    var network: String { metadata.network.uppercased() }
    var destinationPort: String { metadata.destinationPort }

    var startDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: start) ?? ISO8601DateFormatter().date(from: start)
    }

    var startTimeString: String {
        guard let date = startDate else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: date)
    }

    /// Domain suffix for rule creation (e.g. "api.anthropic.com" → "anthropic.com")
    var domainForRule: String {
        let h = metadata.host
        if h.isEmpty { return metadata.destinationIP }
        let parts = h.split(separator: ".")
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: ".")
        }
        return h
    }
}

struct ConnectionMetadata: Codable, Sendable {
    let destinationIP: String
    let destinationPort: String
    let dnsMode: String
    let host: String
    let network: String
    let processPath: String
    let sourceIP: String
    let sourcePort: String
    let type: String
}

struct ConnectionSnapshot: Codable, Sendable {
    let connections: [Connection]?
    let downloadTotal: Int64
    let uploadTotal: Int64
    let memory: Int64?
}

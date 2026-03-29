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

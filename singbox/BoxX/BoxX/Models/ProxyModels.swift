import Foundation

struct ProxyGroup: Identifiable, Codable, Sendable {
    var id: String { name }
    let name: String
    let type: String
    let now: String?
    let all: [String]?
    var displayAll: [String] { all ?? [] }
}

struct ProxyNode: Identifiable, Codable, Sendable {
    var id: String { name }
    let name: String
    let type: String
    let history: [DelayHistory]?
    var lastDelay: Int? { history?.last?.delay }
}

struct DelayHistory: Codable, Sendable {
    let time: String
    let delay: Int
}

struct ProxiesResponse: Codable, Sendable {
    let proxies: [String: ProxyDetail]
}

struct ProxyDetail: Codable, Sendable {
    let name: String
    let type: String
    let now: String?
    let all: [String]?
    let udp: Bool?
    let history: [DelayHistory]?
}

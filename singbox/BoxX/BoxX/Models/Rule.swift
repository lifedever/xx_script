import Foundation

struct Rule: Identifiable, Codable, Sendable {
    let id: Int
    let type: String
    let payload: String
    let proxy: String

    enum CodingKeys: String, CodingKey {
        case type, payload, proxy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        payload = try container.decode(String.self, forKey: .payload)
        proxy = try container.decode(String.self, forKey: .proxy)
        id = 0
    }

    init(id: Int, type: String, payload: String, proxy: String) {
        self.id = id
        self.type = type
        self.payload = payload
        self.proxy = proxy
    }
}

struct RulesResponse: Codable, Sendable {
    let rules: [Rule]
}

import Foundation

struct Subscription: Identifiable, Codable {
    var id: String { name }
    var name: String
    var url: String
}

class SubscriptionManager {
    private var filePath: String {
        let scriptDir = UserDefaults.standard.string(forKey: "scriptDir")
            ?? (NSHomeDirectory() + "/Documents/Dev/myspace/xx_script/singbox")
        return scriptDir + "/subscriptions.json"
    }

    func load() -> [Subscription] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return [] }
        return (try? JSONDecoder().decode([Subscription].self, from: data)) ?? []
    }

    func save(_ subs: [Subscription]) throws {
        let data = try JSONEncoder().encode(subs)
        // Pretty print
        let json = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try pretty.write(to: URL(fileURLWithPath: filePath))
    }
}

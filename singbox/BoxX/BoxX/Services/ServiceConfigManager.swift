import Foundation

struct ServiceConfig: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var geosite: [String]
    var `default`: String?
    var exclude_regions: [String]?
    var include_direct: Bool?
}

class ServiceConfigManager {
    private var filePath: String {
        let scriptDir = UserDefaults.standard.string(forKey: "scriptDir")
            ?? (NSHomeDirectory() + "/Documents/Dev/myspace/xx_script/singbox")
        return scriptDir + "/services.json"
    }

    func load() -> [ServiceConfig] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return [] }
        return (try? JSONDecoder().decode([ServiceConfig].self, from: data)) ?? []
    }

    func save(_ services: [ServiceConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(services)
        try data.write(to: URL(fileURLWithPath: filePath))
    }
}

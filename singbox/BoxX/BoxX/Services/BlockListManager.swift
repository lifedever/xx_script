import Foundation

enum BlockEntryType: String, Codable, CaseIterable {
    case domainSuffix = "domain_suffix"
    case domain = "domain"
    case ipCIDR = "ip_cidr"

    var displayName: String {
        switch self {
        case .domainSuffix: return "DOMAIN-SUFFIX"
        case .domain: return "DOMAIN"
        case .ipCIDR: return "IP-CIDR"
        }
    }
}

struct BlockEntry: Identifiable, Hashable {
    let id = UUID()
    let type: BlockEntryType
    let value: String
}

@MainActor
class BlockListManager {
    private let fileURL: URL

    init(baseDir: URL) {
        let rulesDir = baseDir.appendingPathComponent("rules")
        if !FileManager.default.fileExists(atPath: rulesDir.path) {
            try? FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        }
        self.fileURL = rulesDir.appendingPathComponent("block-custom.json")
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    var filePath: String { fileURL.path }

    func load() -> [BlockEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = json["rules"] as? [[String: Any]] else { return [] }

        var entries: [BlockEntry] = []
        for rule in rules {
            for entryType in BlockEntryType.allCases {
                if let values = rule[entryType.rawValue] as? [String] {
                    for value in values {
                        entries.append(BlockEntry(type: entryType, value: value))
                    }
                }
            }
        }
        return entries
    }

    func add(entries: [BlockEntry]) {
        var existing = load()
        let existingSet = Set(existing.map { "\($0.type.rawValue):\($0.value)" })
        let newEntries = entries.filter { !existingSet.contains("\($0.type.rawValue):\($0.value)") }
        existing.append(contentsOf: newEntries)
        save(entries: existing)
    }

    func remove(entry: BlockEntry) {
        var existing = load()
        existing.removeAll { $0.type == entry.type && $0.value == entry.value }
        save(entries: existing)
    }

    func removeAll() {
        save(entries: [])
    }

    private func save(entries: [BlockEntry]) {
        // Group by type
        var grouped: [BlockEntryType: [String]] = [:]
        for entry in entries {
            grouped[entry.type, default: []].append(entry.value)
        }

        var rules: [[String: Any]] = []
        for entryType in BlockEntryType.allCases {
            if let values = grouped[entryType], !values.isEmpty {
                rules.append([entryType.rawValue: values])
            }
        }

        let json: [String: Any] = ["version": 2, "rules": rules]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Auto-detect entry type from input string
    static func detectType(_ input: String) -> BlockEntryType {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        // Contains / or is pure IP → IP-CIDR
        if trimmed.contains("/") { return .ipCIDR }
        let parts = trimmed.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return .ipCIDR }
        return .domainSuffix
    }

    /// Normalize value (add /32 for bare IPs)
    static func normalizeValue(_ input: String, type: BlockEntryType) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        if type == .ipCIDR && !trimmed.contains("/") {
            return "\(trimmed)/32"
        }
        return trimmed
    }
}

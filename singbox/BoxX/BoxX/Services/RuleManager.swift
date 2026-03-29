import Foundation

/// Manages adding rules to local rule set JSON files in BoxX config directory.
/// Note: ss/rules and clash/rules writing is removed in v2 -- BoxX is self-contained.
final class RuleManager {
    private let baseDir: URL

    init() {
        let fm = FileManager.default
        let sharedDir = URL(fileURLWithPath: "/Library/Application Support/BoxX")
        let userDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BoxX")
        self.baseDir = fm.isWritableFile(atPath: sharedDir.path) ? sharedDir : userDir
    }

    struct AddRuleResult {
        var filesModified: [String] = []
        var errors: [String] = []
    }

    /// Add a rule to local rule set JSON file in BoxX config directory.
    /// - Parameters:
    ///   - type: DOMAIN-SUFFIX, DOMAIN, IP-CIDR, etc.
    ///   - value: the domain or IP
    ///   - target: Proxy, DIRECT, or AI category name
    func addRule(type: String, value: String, target: String) -> AddRuleResult {
        var result = AddRuleResult()

        // Determine which rule file set to use
        let category = mapTargetToCategory(target)

        // Write to rules/*-custom.json (immediate effect)
        let jsonTag = mapCategoryToJsonTag(category)
        let rulesDir = baseDir.appendingPathComponent("rules")
        try? FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        let jsonFile = rulesDir.appendingPathComponent("\(jsonTag).json").path
        if appendToSingboxJson(path: jsonFile, type: type, value: value) {
            result.filesModified.append("rules/\(jsonTag).json")
        } else {
            result.errors.append("Failed to write: rules/\(jsonTag).json")
        }

        return result
    }

    // MARK: - Target mapping

    private func mapTargetToCategory(_ target: String) -> String {
        switch target {
        case "DIRECT": return "Direct"
        case "AI", "OpenAI": return "Ai"
        default: return "Proxy"
        }
    }

    private func mapCategoryToJsonTag(_ category: String) -> String {
        switch category {
        case "Ai": return "ai-custom"
        case "Direct": return "direct-custom"
        default: return "proxy-custom"
        }
    }

    // MARK: - File writers

    /// Append to singbox rule_set JSON (local, immediate effect)
    private func appendToSingboxJson(path: String, type: String, value: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var rules = json["rules"] as? [[String: Any]] ?? []

            let key = jsonKey(for: type)
            // Find existing rule object with this key, or create one
            var found = false
            for i in 0..<rules.count {
                if var values = rules[i][key] as? [String] {
                    if !values.contains(value) {
                        values.append(value)
                        rules[i][key] = values
                    }
                    found = true
                    break
                }
            }
            if !found {
                rules.append([key: [value]])
            }

            json["rules"] = rules
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    private func jsonKey(for ruleType: String) -> String {
        switch ruleType {
        case "DOMAIN-SUFFIX": return "domain_suffix"
        case "DOMAIN": return "domain"
        case "DOMAIN-KEYWORD": return "domain_keyword"
        case "IP-CIDR", "IP-CIDR6": return "ip_cidr"
        default: return "domain_suffix"
        }
    }
}

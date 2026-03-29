import Foundation

/// Manages adding rules to ss/rules, clash/rules, and singbox/rules JSON files
final class RuleManager {
    private let projectDir: String  // xx_script root

    init() {
        let scriptDir = UserDefaults.standard.string(forKey: "scriptDir")
            ?? (NSHomeDirectory() + "/Documents/Dev/myspace/xx_script/singbox")
        // Go up from singbox/ to xx_script/
        self.projectDir = (scriptDir as NSString).deletingLastPathComponent
    }

    struct AddRuleResult {
        var filesModified: [String] = []
        var errors: [String] = []
    }

    /// Add a rule to all rule files (ss, clash, singbox local JSON)
    /// - Parameters:
    ///   - type: DOMAIN-SUFFIX, DOMAIN, IP-CIDR, etc.
    ///   - value: the domain or IP
    ///   - target: Proxy, DIRECT, or AI category name
    func addRule(type: String, value: String, target: String) -> AddRuleResult {
        var result = AddRuleResult()
        let rule = "\(type),\(value)"

        // Determine which rule file set to use
        let category = mapTargetToCategory(target)

        // 1. Write to ss/rules/*.list
        let ssFile = "\(projectDir)/ss/rules/\(category).list"
        if appendToListFile(path: ssFile, line: rule) {
            result.filesModified.append("ss/rules/\(category).list")
        } else {
            result.errors.append("Failed to write: ss/rules/\(category).list")
        }

        // 2. Write to clash/rules/*.yaml
        let clashFile = "\(projectDir)/clash/rules/\(category).yaml"
        if appendToClashYaml(path: clashFile, line: rule) {
            result.filesModified.append("clash/rules/\(category).yaml")
        } else {
            result.errors.append("Failed to write: clash/rules/\(category).yaml")
        }

        // 3. Write to singbox/rules/*-custom.json (immediate effect)
        let jsonTag = mapCategoryToJsonTag(category)
        let jsonFile = "\(projectDir)/singbox/rules/\(jsonTag).json"
        if appendToSingboxJson(path: jsonFile, type: type, value: value) {
            result.filesModified.append("singbox/rules/\(jsonTag).json")
        } else {
            result.errors.append("Failed to write: singbox/rules/\(jsonTag).json")
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

    /// Append a line to a Surge/Shadowrocket .list file
    private func appendToListFile(path: String, line: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let existing = try String(contentsOfFile: path, encoding: .utf8)
            // Check for duplicate
            if existing.contains(line) { return true }
            let newContent = existing.hasSuffix("\n") ? existing + line + "\n" : existing + "\n" + line + "\n"
            try newContent.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Append a rule to a Clash .yaml file (under `payload:`)
    private func appendToClashYaml(path: String, line: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let existing = try String(contentsOfFile: path, encoding: .utf8)
            let yamlLine = "  - \(line)"
            // Check for duplicate
            if existing.contains(yamlLine) { return true }
            let newContent = existing.hasSuffix("\n") ? existing + yamlLine + "\n" : existing + "\n" + yamlLine + "\n"
            try newContent.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

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

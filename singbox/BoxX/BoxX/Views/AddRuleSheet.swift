import SwiftUI

enum AddRuleMode: String, CaseIterable {
    case localRule = "本地规则"
    case ruleSetFile = "规则集文件"
}

struct AddRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    private let initialHost: String
    private let initialDomain: String
    private let initialIP: String
    private let externalDismiss: (() -> Void)?
    private let editingIndex: Int?  // non-nil = editing existing rule at this config index

    @State private var ruleType: String = "DOMAIN-SUFFIX"
    @State private var ruleValue: String = ""
    @State private var selectedOutbound: String = "Proxy"
    @State private var resultMessage: String?
    @State private var isSuccess = false
    @State private var addMode: AddRuleMode = .localRule
    @State private var selectedRuleSetTag: String = ""

    private let ruleTypes = ["DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD", "IP-CIDR", "PROCESS-NAME"]

    /// Standalone init (add new rule)
    init() {
        self.initialHost = ""
        self.initialDomain = ""
        self.initialIP = ""
        self.externalDismiss = nil
        self.editingIndex = nil
    }

    /// Edit existing rule at config index
    init(editingIndex: Int) {
        self.initialHost = ""
        self.initialDomain = ""
        self.initialIP = ""
        self.externalDismiss = nil
        self.editingIndex = editingIndex
    }

    /// Prefilled init (used from ConnectionsView)
    init(host: String, domain: String, ip: String, onDismiss: @escaping () -> Void) {
        self.initialHost = host
        self.initialDomain = domain
        self.initialIP = ip
        self.externalDismiss = onDismiss
        self.editingIndex = nil
    }

    private func close() {
        if let externalDismiss {
            externalDismiss()
        } else {
            dismiss()
        }
    }

    /// All selector/direct outbounds from config for the target picker
    /// Special actions that aren't outbounds but valid rule targets
    private static let specialActions = ["REJECT"]

    private var availableOutbounds: [String] {
        var result = appState.configEngine.config.outbounds.compactMap { outbound -> String? in
            switch outbound {
            case .selector(let s): return s.tag
            case .direct(let d): return d.tag
            default: return nil
            }
        }
        result.append(contentsOf: Self.specialActions)
        return result
    }

    /// Custom rule set tags (direct-custom, proxy-custom, ai-custom, etc.)
    private var customRuleSets: [String] {
        (appState.configEngine.config.route.ruleSet ?? [])
            .compactMap { $0["tag"]?.stringValue }
            .filter { $0.hasSuffix("-custom") }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text(editingIndex != nil ? "编辑规则" : "添加规则")
                    .font(.headline)
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.bar)

            Divider()

            // Form
            Form {
                // Mode picker
                Picker("添加方式", selection: $addMode) {
                    ForEach(AddRuleMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                // Rule type picker
                Picker("规则类型", selection: $ruleType) {
                    ForEach(ruleTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                .onChange(of: ruleType) { _, newType in
                    autoFillValue(for: newType)
                }

                // Rule value
                TextField("匹配值", text: $ruleValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                if addMode == .localRule {
                    // Target outbound picker
                    Picker("出站策略", selection: $selectedOutbound) {
                        ForEach(availableOutbounds, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }

                    // Preview
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("预览: 写入 config.json route.rules")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("""
                            {
                              "\(singboxKey)": ["\(ruleValue)"],
                              "action": "route",
                              "outbound": "\(selectedOutbound)"
                            }
                            """)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.accentColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Rule set file picker
                    if customRuleSets.isEmpty {
                        Text("没有找到自定义规则集（*-custom）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("目标规则集", selection: $selectedRuleSetTag) {
                            ForEach(customRuleSets, id: \.self) { tag in
                                Text(tag).tag(tag)
                            }
                        }

                        // Preview
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("预览: 更新规则集 \(selectedRuleSetTag)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                let url = ruleSetURL(for: selectedRuleSetTag)
                                if let url {
                                    Text(url)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Text("  \(singboxKey): [\"\(ruleValue)\"]")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Color.accentColor)

                                Text("注意: 需要同步更新 GitHub 仓库中的文件")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                // Result message
                if let msg = resultMessage {
                    HStack {
                        Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(isSuccess ? .green : .red)
                        Text(msg)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button("取消") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { saveRule() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ruleValue.isEmpty || (addMode == .ruleSetFile && selectedRuleSetTag.isEmpty))
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear {
            if selectedRuleSetTag.isEmpty, let first = customRuleSets.first {
                selectedRuleSetTag = first
            }

            // Load existing rule data when editing
            if let idx = editingIndex {
                loadExistingRule(at: idx)
            } else if !initialHost.isEmpty {
                ruleType = "DOMAIN-SUFFIX"
                ruleValue = initialDomain.isEmpty ? initialHost : initialDomain
            } else if !initialIP.isEmpty {
                ruleType = "IP-CIDR"
                ruleValue = initialIP + "/32"
            }

            if selectedOutbound.isEmpty || !availableOutbounds.contains(selectedOutbound) {
                selectedOutbound = availableOutbounds.first ?? "Proxy"
            }
        }
    }

    // MARK: - Load Existing Rule

    private func loadExistingRule(at index: Int) {
        let configRules = appState.configEngine.config.route.rules ?? []
        guard index >= 0 && index < configRules.count else { return }
        let rule = configRules[index]

        // Determine type and value
        let typeMapping: [(key: String, type: String)] = [
            ("domain_suffix", "DOMAIN-SUFFIX"),
            ("domain", "DOMAIN"),
            ("domain_keyword", "DOMAIN-KEYWORD"),
            ("ip_cidr", "IP-CIDR"),
            ("process_name", "PROCESS-NAME"),
        ]
        for (key, typeName) in typeMapping {
            if let val = rule[key] {
                ruleType = typeName
                switch val {
                case .array(let arr):
                    ruleValue = arr.compactMap { $0.stringValue }.joined(separator: ", ")
                case .string(let s):
                    ruleValue = s
                default: break
                }
                break
            }
        }

        // Determine outbound
        if rule["action"]?.stringValue == "reject" {
            selectedOutbound = "REJECT"
        } else if let outbound = rule["outbound"]?.stringValue {
            selectedOutbound = outbound
        }
    }

    // MARK: - Helpers

    private var singboxKey: String {
        switch ruleType {
        case "DOMAIN": return "domain"
        case "DOMAIN-SUFFIX": return "domain_suffix"
        case "DOMAIN-KEYWORD": return "domain_keyword"
        case "IP-CIDR": return "ip_cidr"
        case "PROCESS-NAME": return "process_name"
        default: return "domain_suffix"
        }
    }

    private func ruleSetURL(for tag: String) -> String? {
        (appState.configEngine.config.route.ruleSet ?? [])
            .first(where: { $0["tag"]?.stringValue == tag })?["url"]?.stringValue
    }

    private func autoFillValue(for newType: String) {
        guard !initialHost.isEmpty || !initialIP.isEmpty else { return }
        switch newType {
        case "DOMAIN-SUFFIX":
            ruleValue = initialDomain.isEmpty ? initialHost : initialDomain
        case "DOMAIN":
            ruleValue = initialHost
        case "DOMAIN-KEYWORD":
            let parts = (initialDomain.isEmpty ? initialHost : initialDomain).split(separator: ".")
            ruleValue = parts.first.map(String.init) ?? initialHost
        case "IP-CIDR":
            ruleValue = initialIP.isEmpty ? initialHost : initialIP
            if !ruleValue.contains("/") { ruleValue += "/32" }
        default:
            break
        }
    }

    // MARK: - Save

    private func saveRule() {
        guard !ruleValue.isEmpty else { return }

        if addMode == .localRule {
            saveAsLocalRule()
        } else {
            saveToRuleSetFile()
        }
    }

    /// Write directly to config.json route.rules
    private func saveAsLocalRule() {
        // Handle multiple values separated by comma
        let values = ruleValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var ruleDict: [String: JSONValue] = [
            singboxKey: .array(values.map { .string($0) }),
        ]

        if selectedOutbound == "REJECT" {
            ruleDict["action"] = .string("reject")
        } else {
            ruleDict["action"] = .string("route")
            ruleDict["outbound"] = .string(selectedOutbound)
        }

        let newRule = JSONValue.object(ruleDict)
        var rules = appState.configEngine.config.route.rules ?? []

        if let editIdx = editingIndex, editIdx >= 0 && editIdx < rules.count {
            // Update existing rule
            rules[editIdx] = newRule
        } else {
            // Insert new rule after system rules, before service rules
            let insertIdx = rules.firstIndex(where: { rule in
                rule["rule_set"] != nil || rule["domain"] != nil || rule["domain_suffix"] != nil
            }) ?? rules.count
            rules.insert(newRule, at: insertIdx)
        }
        appState.configEngine.config.route.rules = rules

        do {
            try appState.configEngine.save(restartRequired: true)
            close()
        } catch {
            isSuccess = false
            resultMessage = "保存失败: \(error.localizedDescription)"
        }
    }

    /// Write to the local copy of a rule set JSON file (for GitHub sync)
    private func saveToRuleSetFile() {
        guard let ruleSetDef = (appState.configEngine.config.route.ruleSet ?? [])
                .first(where: { $0["tag"]?.stringValue == selectedRuleSetTag }) else {
            isSuccess = false
            resultMessage = "找不到规则集定义"
            return
        }

        // Determine file path: check for local path first, then use tag-based path in project
        let fileURL: URL
        if let path = ruleSetDef["path"]?.stringValue {
            fileURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : appState.configEngine.baseDir.appendingPathComponent(path)
        } else {
            // For remote rule sets, write to the local rules dir inside the app's config directory
            let rulesDir = appState.configEngine.baseDir.appendingPathComponent("rules")
            fileURL = rulesDir.appendingPathComponent("\(selectedRuleSetTag).json")
        }

        // Read existing rule set file
        var ruleSetData: [String: Any] = ["version": 2, "rules": []]
        if let data = try? Data(contentsOf: fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ruleSetData = json
        }

        var rules = ruleSetData["rules"] as? [[String: Any]] ?? []

        // Find or create the rule entry for this key
        let key = singboxKey
        if let idx = rules.firstIndex(where: { $0[key] != nil }) {
            var existing = rules[idx][key] as? [String] ?? []
            if !existing.contains(ruleValue) {
                existing.append(ruleValue)
                rules[idx][key] = existing
            }
        } else {
            rules.append([key: [ruleValue]])
        }

        ruleSetData["rules"] = rules

        do {
            let data = try JSONSerialization.data(withJSONObject: ruleSetData, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            close()
        } catch {
            isSuccess = false
            resultMessage = "写入失败: \(error.localizedDescription)"
        }
    }
}

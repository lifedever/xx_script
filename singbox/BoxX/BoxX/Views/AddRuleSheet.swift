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

    @State private var ruleType: String = "DOMAIN-SUFFIX"
    @State private var ruleValue: String = ""
    @State private var target: String = "Proxy"
    @State private var resultMessage: String?
    @State private var isSuccess = false
    @State private var addMode: AddRuleMode = .localRule
    @State private var selectedRuleSetTag: String = ""

    private let ruleTypes = ["DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD", "IP-CIDR"]
    private let targets = ["Proxy", "DIRECT", "AI"]

    /// Standalone init (used from RulesView via sheet)
    init() {
        self.initialHost = ""
        self.initialDomain = ""
        self.initialIP = ""
        self.externalDismiss = nil
    }

    /// Prefilled init (used from ConnectionsView)
    init(host: String, domain: String, ip: String, onDismiss: @escaping () -> Void) {
        self.initialHost = host
        self.initialDomain = domain
        self.initialIP = ip
        self.externalDismiss = onDismiss
    }

    private func close() {
        if let externalDismiss {
            externalDismiss()
        } else {
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text(String(localized: "addrule.title"))
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

                if addMode == .ruleSetFile {
                    Picker("目标规则集", selection: $selectedRuleSetTag) {
                        ForEach(localRuleSets, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }
                }

                // Rule type picker
                Picker(String(localized: "addrule.type"), selection: $ruleType) {
                    ForEach(ruleTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                .onChange(of: ruleType) { _, newType in
                    autoFillValue(for: newType)
                }

                // Rule value (editable)
                TextField(String(localized: "addrule.value"), text: $ruleValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                if addMode == .localRule {
                    // Target picker
                    Picker(String(localized: "addrule.target"), selection: $target) {
                        ForEach(targets, id: \.self) { t in
                            Label(targetLabel(t), systemImage: targetIcon(t)).tag(t)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    // Preview
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "addrule.preview"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("ss/rules/\(targetFile).list")
                                .font(.caption.monospaced())
                            Text("  \(ruleType),\(ruleValue)")
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.accentColor)

                            Text("clash/rules/\(targetFile).yaml")
                                .font(.caption.monospaced())
                            Text("  - \(ruleType),\(ruleValue)")
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.accentColor)

                            Text("singbox/rules/\(jsonTag).json")
                                .font(.caption.monospaced())
                            Text("  \(jsonKey): [\"\(jsonValue)\"]")
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Rule set file preview
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("预览")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("规则集: \(selectedRuleSetTag)")
                                .font(.caption.monospaced())
                            Text("  \(jsonKey): [\"\(ruleValue)\"]")
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.bottom, 0)

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button(String(localized: "addrule.cancel")) {
                    close()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "addrule.save")) {
                    saveRule()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ruleValue.isEmpty || (addMode == .ruleSetFile && selectedRuleSetTag.isEmpty))
            }
            .padding()
        }
        .frame(width: 480, height: 580)
        .onAppear {
            // Initialize rule set tag
            if selectedRuleSetTag.isEmpty, let first = localRuleSets.first {
                selectedRuleSetTag = first
            }
            if !initialHost.isEmpty && !initialIP.isEmpty {
                ruleType = "DOMAIN-SUFFIX"
                ruleValue = initialDomain
            } else if !initialIP.isEmpty {
                ruleType = "IP-CIDR"
                ruleValue = initialIP + "/32"
            } else if !initialHost.isEmpty {
                ruleValue = initialHost
            }
        }
    }

    // MARK: - Helpers

    private func autoFillValue(for newType: String) {
        guard !initialHost.isEmpty || !initialIP.isEmpty else { return }
        switch newType {
        case "DOMAIN-SUFFIX":
            ruleValue = initialDomain
        case "DOMAIN":
            ruleValue = initialHost
        case "DOMAIN-KEYWORD":
            let parts = initialDomain.split(separator: ".")
            ruleValue = parts.first.map(String.init) ?? initialDomain
        case "IP-CIDR":
            ruleValue = initialIP.isEmpty ? initialHost : initialIP
            if !ruleValue.contains("/") { ruleValue += "/32" }
        default:
            break
        }
    }

    private var targetFile: String {
        switch target {
        case "DIRECT": return "Direct"
        case "AI": return "Ai"
        default: return "Proxy"
        }
    }

    private var jsonTag: String {
        switch target {
        case "DIRECT": return "direct-custom"
        case "AI": return "ai-custom"
        default: return "proxy-custom"
        }
    }

    private var jsonKey: String {
        switch ruleType {
        case "DOMAIN-SUFFIX": return "domain_suffix"
        case "DOMAIN": return "domain"
        case "DOMAIN-KEYWORD": return "domain_keyword"
        case "IP-CIDR": return "ip_cidr"
        default: return "domain_suffix"
        }
    }

    private var jsonValue: String {
        ruleValue
    }

    private func targetLabel(_ t: String) -> String {
        switch t {
        case "Proxy": return "Proxy (\(String(localized: "addrule.target.proxy")))"
        case "DIRECT": return "DIRECT (\(String(localized: "addrule.target.direct")))"
        case "AI": return "AI (\(String(localized: "addrule.target.ai")))"
        default: return t
        }
    }

    private func targetIcon(_ t: String) -> String {
        switch t {
        case "Proxy": return "globe"
        case "DIRECT": return "arrow.right"
        case "AI": return "brain"
        default: return "circle"
        }
    }

    private var localRuleSets: [String] {
        (appState.configEngine.config.route.ruleSet ?? [])
            .filter { $0["type"]?.stringValue == "local" }
            .compactMap { $0["tag"]?.stringValue }
    }

    private func saveRule() {
        if addMode == .ruleSetFile {
            saveToRuleSetFile(tag: selectedRuleSetTag, ruleType: ruleType, value: ruleValue)
            return
        }

        let manager = RuleManager()
        let result = manager.addRule(type: ruleType, value: ruleValue, target: target)

        if result.errors.isEmpty {
            isSuccess = true
            let files = result.filesModified.joined(separator: ", ")
            resultMessage = String(format: String(localized: "addrule.success"), files)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                close()
            }
        } else {
            isSuccess = false
            resultMessage = result.errors.joined(separator: "\n")
        }
    }

    private func saveToRuleSetFile(tag: String, ruleType: String, value: String) {
        guard let ruleSetDef = (appState.configEngine.config.route.ruleSet ?? [])
                .first(where: { $0["tag"]?.stringValue == tag }),
              let path = ruleSetDef["path"]?.stringValue else {
            isSuccess = false
            resultMessage = "找不到规则集文件路径"
            return
        }

        let fileURL: URL
        if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path)
        } else {
            fileURL = appState.configEngine.baseDir.appendingPathComponent(path)
        }

        // Read existing rule set file
        var ruleSetData: [String: Any] = ["version": 2, "rules": []]
        if let data = try? Data(contentsOf: fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ruleSetData = json
        }

        var rules = ruleSetData["rules"] as? [[String: Any]] ?? []

        // Map rule type to sing-box key
        let key: String
        switch ruleType {
        case "DOMAIN": key = "domain"
        case "DOMAIN-SUFFIX": key = "domain_suffix"
        case "DOMAIN-KEYWORD": key = "domain_keyword"
        case "IP-CIDR": key = "ip_cidr"
        default: key = "domain_suffix"
        }

        // Find or create the rule entry for this key
        if let idx = rules.firstIndex(where: { $0[key] != nil }) {
            var existing = rules[idx][key] as? [String] ?? []
            if !existing.contains(value) {
                existing.append(value)
                rules[idx][key] = existing
            }
        } else {
            rules.append([key: [value]])
        }

        ruleSetData["rules"] = rules

        // Write back
        if let data = try? JSONSerialization.data(withJSONObject: ruleSetData, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try data.write(to: fileURL, options: .atomic)
                isSuccess = true
                resultMessage = "已添加到规则集: \(tag)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    close()
                }
            } catch {
                isSuccess = false
                resultMessage = "写入失败: \(error.localizedDescription)"
            }
        } else {
            isSuccess = false
            resultMessage = "JSON 序列化失败"
        }
    }
}

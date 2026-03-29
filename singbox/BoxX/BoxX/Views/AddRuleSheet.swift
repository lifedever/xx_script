import SwiftUI

struct AddRuleSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let initialHost: String
    private let initialDomain: String
    private let initialIP: String
    private let externalDismiss: (() -> Void)?

    @State private var ruleType: String = "DOMAIN-SUFFIX"
    @State private var ruleValue: String = ""
    @State private var target: String = "Proxy"
    @State private var resultMessage: String?
    @State private var isSuccess = false

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
                .disabled(ruleValue.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear {
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

    private func saveRule() {
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
}

import SwiftUI

struct BuiltinRulesView: View {
    @Environment(AppState.self) private var appState

    @State private var enabledRuleSetIDs: Set<String> = []
    @State private var editingRuleSet: BuiltinRuleSet?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("内置规则")
                    .font(.title2)
                    .bold()
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("基于 sing-geosite 的预置规则集")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ], spacing: 10) {
                        ForEach(BuiltinRuleSet.all) { ruleSet in
                            builtinRuleSetCard(ruleSet)
                        }
                    }
                }
                .padding()
            }
        }
        .task {
            loadEnabledRuleSets()
        }
        .sheet(item: $editingRuleSet) { ruleSet in
            BuiltinRuleSetEditSheet(ruleSet: ruleSet) {
                loadEnabledRuleSets()
            }
        }
    }

    // MARK: - Card View

    private func builtinRuleSetCard(_ ruleSet: BuiltinRuleSet) -> some View {
        let isEnabled = enabledRuleSetIDs.contains(ruleSet.id)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ruleSet.displayName)
                    .font(.callout.bold())
                    .lineLimit(1)

                HStack(spacing: 4) {
                    ForEach(ruleSet.geositeNames, id: \.self) { name in
                        Text(name)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }

                Text(currentOutbound(for: ruleSet))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if newValue {
                        enabledRuleSetIDs.insert(ruleSet.id)
                        addRuleSetToConfig(ruleSet)
                    } else {
                        enabledRuleSetIDs.remove(ruleSet.id)
                        removeRuleSetFromConfig(ruleSet)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(isEnabled ? 1.0 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { editingRuleSet = ruleSet }
    }

    /// Read current outbound for a builtin rule set from config (not the hardcoded default)
    private func currentOutbound(for ruleSet: BuiltinRuleSet) -> String {
        let rules = appState.configEngine.config.route.rules ?? []
        let geositeTags = Set(ruleSet.geositeNames.map { "geosite-\($0)" })
        for rule in rules {
            guard let refs = rule["rule_set"]?.arrayValue else { continue }
            let tags = Set(refs.compactMap { $0.stringValue })
            if !tags.isDisjoint(with: geositeTags) {
                if rule["action"]?.stringValue == "reject" { return "REJECT" }
                return rule["outbound"]?.stringValue ?? ruleSet.defaultOutbound
            }
        }
        return ruleSet.defaultOutbound
    }

    // MARK: - Rule Set Config Helpers

    private func loadEnabledRuleSets() {
        let existingTags = Set(
            (appState.configEngine.config.route.ruleSet ?? [])
                .compactMap { $0["tag"]?.stringValue }
        )
        enabledRuleSetIDs = Set(
            BuiltinRuleSet.all.filter { ruleSet in
                ruleSet.geositeNames.allSatisfy { existingTags.contains("geosite-\($0)") }
            }.map(\.id)
        )
    }

    private func addRuleSetToConfig(_ ruleSet: BuiltinRuleSet) {
        // Add rule_set definitions (geosite remote URLs)
        var currentRuleSets = appState.configEngine.config.route.ruleSet ?? []
        for def in ruleSet.ruleSetDefinitions {
            let tag = def["tag"]?.stringValue ?? ""
            if !currentRuleSets.contains(where: { $0["tag"]?.stringValue == tag }) {
                currentRuleSets.append(def)
            }
        }
        appState.configEngine.config.route.ruleSet = currentRuleSets

        // Add route rule
        var currentRules = appState.configEngine.config.route.rules ?? []
        currentRules.append(ruleSet.routeRule)
        appState.configEngine.config.route.rules = currentRules

        do {
            try appState.configEngine.save(restartRequired: true)
        } catch {
            appState.showAlert("保存失败: \(error.localizedDescription)")
        }
    }

    private func removeRuleSetFromConfig(_ ruleSet: BuiltinRuleSet) {
        let tagsToRemove = Set(ruleSet.geositeNames.map { "geosite-\($0)" })

        // Remove rule_set definitions
        appState.configEngine.config.route.ruleSet?.removeAll { item in
            guard let tag = item["tag"]?.stringValue else { return false }
            return tagsToRemove.contains(tag)
        }

        // Remove route rules that reference these rule sets
        appState.configEngine.config.route.rules?.removeAll { item in
            guard let ruleSetRefs = item["rule_set"]?.arrayValue else { return false }
            let refTags = Set(ruleSetRefs.compactMap { $0.stringValue })
            return !refTags.isDisjoint(with: tagsToRemove)
        }

        do {
            try appState.configEngine.save(restartRequired: true)
        } catch {
            appState.showAlert("保存失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - Built-in Rule Set Edit Sheet

struct BuiltinRuleSetEditSheet: View {
    let ruleSet: BuiltinRuleSet
    let onSave: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOutbound: String
    @State private var geositeEntries: [String]

    init(ruleSet: BuiltinRuleSet, onSave: @escaping () -> Void) {
        self.ruleSet = ruleSet
        self.onSave = onSave
        _selectedOutbound = State(initialValue: ruleSet.defaultOutbound)
        _geositeEntries = State(initialValue: ruleSet.geositeNames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑规则集: \(ruleSet.displayName)")
                .font(.headline)

            // Outbound picker
            HStack {
                Text("出站策略组")
                Spacer()
                Picker("", selection: $selectedOutbound) {
                    ForEach(availableOutbounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .frame(width: 200)
            }

            // Geosite entries
            Text("Geosite 规则")
                .font(.subheadline)

            ForEach(Array(geositeEntries.enumerated()), id: \.offset) { index, entry in
                HStack {
                    TextField("geosite name", text: Binding(
                        get: { geositeEntries.indices.contains(index) ? geositeEntries[index] : "" },
                        set: { if geositeEntries.indices.contains(index) { geositeEntries[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                    Button {
                        geositeEntries.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("添加 geosite") {
                geositeEntries.append("")
            }
            .controlSize(.small)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save()
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            let geositeTags = Set(ruleSet.geositeNames.map { "geosite-\($0)" })
            if let rules = appState.configEngine.config.route.rules {
                for rule in rules {
                    guard let refs = rule["rule_set"]?.arrayValue else { continue }
                    let refTags = Set(refs.compactMap { $0.stringValue })
                    if !refTags.isDisjoint(with: geositeTags),
                       let outbound = rule["outbound"]?.stringValue {
                        selectedOutbound = outbound
                        break
                    }
                }
            }
        }
    }

    private var availableOutbounds: [String] {
        appState.configEngine.config.outbounds.compactMap { outbound in
            switch outbound {
            case .selector(let s): return s.tag
            case .direct(let d): return d.tag
            default: return nil
            }
        }
    }

    private func save() {
        let oldTags = Set(ruleSet.geositeNames.map { "geosite-\($0)" })
        let newNames = geositeEntries.filter { !$0.isEmpty }
        let newRuleSetTags = newNames.map { "geosite-\($0)" }

        // Remove old route rule
        appState.configEngine.config.route.rules?.removeAll { item in
            guard let refs = item["rule_set"]?.arrayValue else { return false }
            let refTags = Set(refs.compactMap { $0.stringValue })
            return !refTags.isDisjoint(with: oldTags)
        }

        // Add new route rule
        if !newRuleSetTags.isEmpty {
            let newRule = JSONValue.object([
                "rule_set": .array(newRuleSetTags.map { .string($0) }),
                "action": .string("route"),
                "outbound": .string(selectedOutbound),
            ])
            var rules = appState.configEngine.config.route.rules ?? []
            rules.append(newRule)
            appState.configEngine.config.route.rules = rules
        }

        // Remove old geosite rule_set definitions
        appState.configEngine.config.route.ruleSet?.removeAll { item in
            guard let tag = item["tag"]?.stringValue else { return false }
            return oldTags.contains(tag)
        }

        // Add new geosite definitions
        var currentRuleSets = appState.configEngine.config.route.ruleSet ?? []
        for name in newNames {
            let tag = "geosite-\(name)"
            let def = JSONValue.object([
                "type": .string("remote"),
                "tag": .string(tag),
                "format": .string("binary"),
                "url": .string("https://testingcf.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-\(name).srs"),
                "download_detour": .string("DIRECT"),
            ])
            if !currentRuleSets.contains(where: { $0["tag"]?.stringValue == tag }) {
                currentRuleSets.append(def)
            }
        }
        appState.configEngine.config.route.ruleSet = currentRuleSets

        do {
            try appState.configEngine.save(restartRequired: true)
        } catch {
            appState.showAlert("保存失败: \(error.localizedDescription)")
        }
    }
}

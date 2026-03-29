import SwiftUI

struct RulesView: View {
    @Environment(AppState.self) private var appState

    @State private var rules: [Rule] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var showAddRule = false
    @State private var enabledRuleSetIDs: Set<String> = []
    @State private var editingRuleSet: BuiltinRuleSet?

    var filteredRules: [Rule] {
        if searchText.isEmpty { return rules }
        return rules.filter {
            $0.type.localizedCaseInsensitiveContains(searchText)
            || $0.payload.localizedCaseInsensitiveContains(searchText)
            || $0.proxy.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("规则")
                    .font(.title2)
                    .bold()
                Spacer()
                TextField("搜索...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button {
                    Task { await loadRules() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新规则")
                Button {
                    showAddRule = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加规则")
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        routeRulesSection
                        Divider()
                        configuredRuleSetsSection
                        Divider()
                        builtinRuleSetsSection
                    }
                    .padding()
                }
            }
        }
        .task {
            loadEnabledRuleSets()
            await loadRules()
        }
        .sheet(isPresented: $showAddRule) {
            AddRuleSheet()
        }
        .sheet(item: $editingRuleSet) { ruleSet in
            BuiltinRuleSetEditSheet(ruleSet: ruleSet) {
                loadEnabledRuleSets()
            }
        }
    }

    // MARK: - Route Rules Section

    private var routeRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("路由规则")
                    .font(.headline)
                Text("\(filteredRules.count) 条规则")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if filteredRules.isEmpty {
                Text("暂无规则")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                // Table header
                HStack(spacing: 0) {
                    Text("#")
                        .frame(width: 40, alignment: .leading)
                    Text("类型")
                        .frame(width: 140, alignment: .leading)
                    Text("匹配内容")
                        .frame(minWidth: 200, alignment: .leading)
                    Spacer()
                    Text("策略组")
                        .frame(width: 140, alignment: .leading)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredRules.prefix(2000))) { rule in
                        ruleRow(rule)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        HStack(spacing: 0) {
            Text("\(rule.id + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            ruleTypeBadge(rule.type)
                .frame(width: 140, alignment: .leading)

            Text(rule.payload)
                .font(.body.monospaced())
                .lineLimit(1)
                .frame(minWidth: 200, alignment: .leading)

            Spacer()

            Text(rule.proxy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(rule.id % 2 == 0 ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func ruleTypeBadge(_ type: String) -> some View {
        Text(type)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor(for: type).opacity(0.12))
            .foregroundStyle(badgeColor(for: type))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func badgeColor(for type: String) -> Color {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
            return .blue
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR":
            return .orange
        case "GEOSITE", "GEOIP":
            return .purple
        case "MATCH":
            return .gray
        case "RULE-SET":
            return .green
        default:
            return .secondary
        }
    }

    // MARK: - Built-in Rule Sets Section

    private var builtinRuleSetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内置规则集")
                .font(.headline)
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
    }

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

                Text(ruleSet.defaultOutbound)
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
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(isEnabled ? 1.0 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { editingRuleSet = ruleSet }
    }

    // MARK: - Configured Rule Sets Section

    private var configuredRuleSetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已配置规则集")
                .font(.headline)
            Text("当前 config.json 中的规则集定义")
                .font(.caption)
                .foregroundStyle(.secondary)

            let ruleSets = appState.configEngine.config.route.ruleSet ?? []
            if ruleSets.isEmpty {
                Text("暂无规则集")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 8) {
                    ForEach(Array(ruleSets.enumerated()), id: \.offset) { _, ruleSet in
                        configuredRuleSetCard(ruleSet)
                    }
                }
            }
        }
    }

    private func configuredRuleSetCard(_ ruleSet: JSONValue) -> some View {
        let tag = ruleSet["tag"]?.stringValue ?? "unknown"
        let type = ruleSet["type"]?.stringValue ?? "unknown"
        let format = ruleSet["format"]?.stringValue ?? ""
        let url = ruleSet["url"]?.stringValue
        let path = ruleSet["path"]?.stringValue

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tag)
                    .font(.callout.bold())
                    .lineLimit(1)
                Spacer()
                Text(type)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(type == "local" ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                    .foregroundStyle(type == "local" ? Color.green : Color.blue)
                    .clipShape(Capsule())
            }

            if let url = url {
                Text(url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let path = path {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !format.isEmpty {
                Text(format)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

        try? appState.configEngine.save()
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

        try? appState.configEngine.save()
    }

    // MARK: - Data Loading

    private func loadRules() async {
        isLoading = true
        defer { isLoading = false }
        rules = (try? await appState.api.getRules()) ?? []
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
        // Will be overridden in onAppear to read from config
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
            // Read current outbound from config route rules
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

        try? appState.configEngine.save()
    }
}

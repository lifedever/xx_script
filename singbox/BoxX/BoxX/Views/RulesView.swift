import SwiftUI

struct RulesView: View {
    @Environment(AppState.self) private var appState

    @State private var rules: [Rule] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var showAddRule = false
    @State private var enabledRuleSetIDs: Set<String> = []

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
                        builtinRuleSetsSection
                        Divider()
                        remoteRuleSetsSection
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
    }

    // MARK: - Remote Rule Sets Section (placeholder)

    private var remoteRuleSetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("远程规则集")
                    .font(.headline)
                Spacer()
                Button {
                    // TODO: Add remote rule set URL
                } label: {
                    Label("添加 URL", systemImage: "plus")
                }
                .controlSize(.small)
            }
            Text("从远程 URL 加载自定义规则集（即将支持）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        }
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

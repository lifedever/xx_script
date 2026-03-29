import SwiftUI

struct RouteRulesView: View {
    @Environment(AppState.self) private var appState

    @State private var rules: [Rule] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var showAddRule = false
    @State private var selectedRuleIndex: Int?
    @State private var editingRuleIndex: Int?
    @State private var deletingRuleIndex: Int?

    /// Wrapper to drive sheet(item:) for editing
    private struct EditItem: Identifiable {
        let id: Int  // config index
    }
    @State private var editItem: EditItem?

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
                Text("路由规则")
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
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
                                Text("操作")
                                    .frame(width: 110, alignment: .center)
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
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding()
                }
            }
        }
        .task {
            await loadRules()
        }
        .sheet(isPresented: $showAddRule) {
            AddRuleSheet()
                .onDisappear { Task { await loadRules() } }
        }
        .sheet(item: $editItem) { item in
            AddRuleSheet(editingIndex: item.id)
                .onDisappear { Task { await loadRules() } }
        }
        .confirmationDialog("确认删除", isPresented: .init(
            get: { deletingRuleIndex != nil },
            set: { if !$0 { deletingRuleIndex = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let idx = deletingRuleIndex { deleteRule(at: idx) }
                deletingRuleIndex = nil
            }
            Button("取消", role: .cancel) { deletingRuleIndex = nil }
        } message: {
            Text("确定要删除这条规则吗？此操作不可撤销。")
        }
    }

    // MARK: - Row Views

    /// System rule types that cannot be edited or deleted
    private static let systemTypes: Set<String> = ["SNIFF", "HIJACK-DNS", "IP-PRIVATE", "REJECT", "MODE"]

    private var isSystemRule: (Rule) -> Bool {
        { rule in Self.systemTypes.contains(rule.type) }
    }

    /// Human-readable description for system rules
    private func systemRuleDescription(_ rule: Rule) -> String {
        switch rule.type {
        case "SNIFF":
            return "协议嗅探"
        case "HIJACK-DNS":
            return "DNS 劫持"
        case "IP-PRIVATE":
            return "私有 IP 地址"
        case "REJECT":
            return "拒绝连接"
        case "MODE":
            // Show the mode value (e.g., "Direct", "Global")
            let modeValue = rule.proxy
            return modeValue == "—" ? "模式匹配" : modeValue
        default:
            return "—"
        }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        let isSelected = selectedRuleIndex == rule.id
        let isSystem = isSystemRule(rule)

        return HStack(spacing: 0) {
            Text("\(rule.id + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            ruleTypeBadge(rule.type)
                .frame(width: 140, alignment: .leading)

            Group {
                if isSystem && rule.payload == "—" {
                    Text(systemRuleDescription(rule))
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    Text(rule.payload)
                        .font(.body.monospaced())
                }
            }
            .lineLimit(1)
            .frame(minWidth: 200, alignment: .leading)

            Spacer()

            Text(rule.proxy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            // 操作按钮
            HStack(spacing: 6) {
                if !isSystem {
                    Button("编辑") {
                        editItem = EditItem(id: rule.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("删除") {
                        deletingRuleIndex = rule.id
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
            }
            .frame(width: 120, alignment: .center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                : (rule.id % 2 == 0 ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial.opacity(0.5)))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRuleIndex = (selectedRuleIndex == rule.id) ? nil : rule.id
        }
        .contextMenu {
            if !isSystem {
                Button { editItem = EditItem(id: rule.id) } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button("删除", role: .destructive) { deletingRuleIndex = rule.id }
            } else {
                Text("系统规则，不可编辑")
            }
        }
    }

    private func deleteRule(at index: Int) {
        var configRules = appState.configEngine.config.route.rules ?? []
        guard index >= 0 && index < configRules.count else { return }
        configRules.remove(at: index)
        appState.configEngine.config.route.rules = configRules
        do {
            try appState.configEngine.save(restartRequired: true)
        } catch {
            appState.showAlert("删除失败: \(error.localizedDescription)")
        }
        selectedRuleIndex = nil
        Task { await loadRules() }
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
        case "SNIFF", "HIJACK-DNS":
            return .teal
        case "IP-PRIVATE":
            return .mint
        case "REJECT":
            return .red
        case "MODE":
            return .indigo
        default:
            return .secondary
        }
    }

    // MARK: - Data Loading

    private func loadRules() async {
        isLoading = true
        defer { isLoading = false }
        let configRules = appState.configEngine.config.route.rules ?? []
        // Filter out RULE-SET rules (managed in 规则集 page)
        let allRules = configRules.enumerated().compactMap { (index, rule) -> Rule? in
            if rule["rule_set"] != nil { return nil }
            return Rule(
                id: index,
                type: Self.extractRuleType(from: rule),
                payload: Self.extractRulePayload(from: rule),
                proxy: rule["outbound"]?.stringValue ?? rule["action"]?.stringValue ?? "—"
            )
        }
        // Sort: editable rules first, system rules at bottom
        let editable = allRules.filter { !Self.systemTypes.contains($0.type) }
        let system = allRules.filter { Self.systemTypes.contains($0.type) }
        rules = editable + system
    }

    /// Extract rule type from a JSONValue rule object
    private static func extractRuleType(from rule: JSONValue) -> String {
        let typeKeys: [(key: String, label: String)] = [
            ("domain_suffix", "DOMAIN-SUFFIX"),
            ("domain", "DOMAIN"),
            ("domain_keyword", "DOMAIN-KEYWORD"),
            ("domain_regex", "DOMAIN-REGEX"),
            ("ip_cidr", "IP-CIDR"),
            ("source_ip_cidr", "SRC-IP-CIDR"),
            ("rule_set", "RULE-SET"),
            ("process_name", "PROCESS-NAME"),
            ("process_path", "PROCESS-PATH"),
            ("protocol", "PROTOCOL"),
            ("port", "PORT"),
            ("source_port", "SRC-PORT"),
            ("network", "NETWORK"),
            ("ip_is_private", "IP-PRIVATE"),
            ("clash_mode", "MODE"),
        ]
        for (key, label) in typeKeys {
            if rule[key] != nil { return label }
        }
        if let action = rule["action"]?.stringValue, rule["outbound"] == nil {
            return action.uppercased()
        }
        return "UNKNOWN"
    }

    /// Extract match payload from a JSONValue rule object
    private static func extractRulePayload(from rule: JSONValue) -> String {
        let matchKeys = [
            "domain_suffix", "domain", "domain_keyword", "domain_regex",
            "ip_cidr", "source_ip_cidr", "rule_set", "process_name",
            "process_path", "protocol", "port", "source_port", "network",
        ]
        for key in matchKeys {
            if let val = rule[key] {
                switch val {
                case .string(let s):
                    return s
                case .array(let arr):
                    let items = arr.compactMap { $0.stringValue }
                    if items.count <= 3 {
                        return items.joined(separator: ", ")
                    }
                    return "\(items.prefix(3).joined(separator: ", ")) (+\(items.count - 3))"
                case .bool(let b):
                    return String(b)
                default:
                    break
                }
            }
        }
        // For MODE rules, show the clash_mode value
        if let modeVal = rule["clash_mode"] {
            switch modeVal {
            case .string(let s): return s
            default: break
            }
        }
        return "—"
    }
}

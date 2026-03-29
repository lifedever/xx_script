import SwiftUI

struct RouteRulesView: View {
    @Environment(AppState.self) private var appState

    @State private var rules: [Rule] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var showAddRule = false

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
        }
    }

    // MARK: - Row Views

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
        .background(rule.id % 2 == 0 ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial.opacity(0.5)))
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

    // MARK: - Data Loading

    private func loadRules() async {
        isLoading = true
        defer { isLoading = false }
        let configRules = appState.configEngine.config.route.rules ?? []
        rules = configRules.enumerated().map { (index, rule) in
            Rule(
                id: index,
                type: Self.extractRuleType(from: rule),
                payload: Self.extractRulePayload(from: rule),
                proxy: rule["outbound"]?.stringValue ?? rule["action"]?.stringValue ?? "—"
            )
        }
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
        return "—"
    }
}

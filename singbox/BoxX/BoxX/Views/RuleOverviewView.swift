import SwiftUI

struct RuleOverviewView: View {
    @Environment(AppState.self) private var appState
    @State private var items: [RuleOverviewItem] = []
    @State private var searchText = ""
    @State private var selectedId: Int?

    private var filteredItems: [RuleOverviewItem] {
        if searchText.isEmpty { return items }
        return items.filter {
            $0.type.localizedCaseInsensitiveContains(searchText) ||
            $0.value.localizedCaseInsensitiveContains(searchText) ||
            $0.outbound.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("规则总览")
                    .font(.title2)
                    .bold()
                Text("\(items.count) 条规则，按执行优先级排列")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("搜索...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button {
                    loadRules()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Table header
                    HStack(spacing: 0) {
                        Text("#")
                            .frame(width: 30, alignment: .leading)
                        Text("分类")
                            .frame(width: 60, alignment: .leading)
                        Text("类型")
                            .frame(width: 140, alignment: .leading)
                        Text("匹配内容")
                            .frame(minWidth: 250, alignment: .leading)
                        Spacer()
                        Text("出站 / 动作")
                            .frame(width: 140, alignment: .leading)
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    let sectionStarts = computeSectionStarts(filteredItems)

                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                            if sectionStarts.contains(index) {
                                sectionHeader(item.category)
                            }
                            ruleRow(item, index: index)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding()
            }
        }
        .onAppear { loadRules() }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sectionIcon(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.bold())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
    }

    private func sectionIcon(_ category: String) -> String {
        switch category {
        case "系统规则": return "gearshape"
        case "自定义规则": return "person"
        case "服务分流": return "shield.checkered"
        case "通用规则": return "globe"
        default: return "list.bullet"
        }
    }

    private func ruleRow(_ item: RuleOverviewItem, index: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(item.priority)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .leading)

            categoryBadge(item.category)
                .frame(width: 60, alignment: .leading)

            typeBadge(item.type)
                .frame(width: 140, alignment: .leading)

            Text(item.value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(item.category == "系统规则" ? .tertiary : .primary)
                .frame(minWidth: 250, alignment: .leading)

            Spacer()

            outboundLabel(item.outbound)
                .frame(width: 140, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            selectedId == item.id
                ? Color.accentColor.opacity(0.15)
                : (index % 2 == 0 ? Color.clear : Color.gray.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedId = (selectedId == item.id) ? nil : item.id
        }
    }

    private func computeSectionStarts(_ items: [RuleOverviewItem]) -> Set<Int> {
        var starts = Set<Int>()
        var last = ""
        for (i, item) in items.enumerated() {
            if item.category != last {
                starts.insert(i)
                last = item.category
            }
        }
        return starts
    }

    // MARK: - Badges

    private func categoryBadge(_ category: String) -> some View {
        let (color, short): (Color, String) = {
            switch category {
            case "系统规则": return (.gray, "系统")
            case "自定义规则": return (.blue, "自定义")
            case "服务分流": return (.purple, "服务")
            case "通用规则": return (.orange, "通用")
            default: return (.secondary, "?")
            }
        }()
        return Text(short)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func typeBadge(_ type: String) -> some View {
        Text(type)
            .font(.caption2.monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(typeColor(type).opacity(0.12))
            .foregroundStyle(typeColor(type))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD": return .blue
        case "IP-CIDR", "IP-PRIVATE": return .orange
        case "RULE-SET": return .green
        case "PROCESS-NAME", "PROCESS-PATH": return .cyan
        case "SNIFF": return .teal
        case "HIJACK-DNS": return .teal
        case "REJECT": return .red
        case "MODE": return .indigo
        default: return .secondary
        }
    }

    private func outboundLabel(_ outbound: String) -> some View {
        HStack(spacing: 4) {
            if outbound == "DIRECT" {
                Text(outbound).font(.caption.bold()).foregroundStyle(.green)
            } else if outbound == "reject" || outbound == "sniff" || outbound == "hijack-dns" {
                Text(outbound).font(.caption).foregroundStyle(.secondary)
            } else {
                Circle().fill(Color.blue).frame(width: 5, height: 5)
                Text(outbound).font(.caption).foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Data Loading

    private func loadRules() {
        // Read from runtime-config.json (the actual running config)
        let runtimeURL = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json")
        let rules: [JSONValue]
        if let data = try? Data(contentsOf: runtimeURL),
           let config = try? JSONDecoder().decode(SingBoxConfig.self, from: data) {
            rules = config.route.rules ?? []
        } else {
            // Fallback to config.json
            rules = appState.configEngine.config.route.rules ?? []
        }
        let genericOutbounds: Set<String> = ["Proxy", "DIRECT", "reject"]

        items = rules.enumerated().map { (i, r) in
            let action = r["action"]?.stringValue ?? ""
            let outbound = r["outbound"]?.stringValue ?? action
            let isLogical = r["type"]?.stringValue == "logical"

            // Determine type
            let type: String
            if isLogical {
                type = action.uppercased()
            } else if action == "sniff" {
                type = "SNIFF"
            } else {
                type = Self.extractType(from: r)
            }

            // Determine value
            let value: String
            if isLogical {
                if case .array(let subs) = r["rules"] {
                    value = subs.compactMap { sub -> String? in
                        for key in ["protocol", "port"] {
                            if let v = sub[key] { return "\(key)=\(v.stringValue ?? "")" }
                        }
                        return nil
                    }.joined(separator: " | ")
                } else { value = "—" }
            } else if action == "sniff" {
                value = "协议嗅探"
            } else {
                value = Self.extractValue(from: r)
            }

            // Determine category
            let category: String
            let systemActions: Set<String> = ["sniff", "hijack-dns", "reject"]
            if systemActions.contains(action) || r["ip_is_private"] != nil || r["clash_mode"] != nil || isLogical {
                category = "系统规则"
            } else if r["rule_set"] != nil {
                category = genericOutbounds.contains(outbound) ? "通用规则" : "服务分流"
            } else {
                category = "自定义规则"
            }

            return RuleOverviewItem(
                id: i,
                priority: i + 1,
                category: category,
                type: type,
                value: value,
                outbound: outbound
            )
        }
    }

    private static func extractType(from rule: JSONValue) -> String {
        let keys: [(String, String)] = [
            ("domain_suffix", "DOMAIN-SUFFIX"), ("domain", "DOMAIN"),
            ("domain_keyword", "DOMAIN-KEYWORD"), ("ip_cidr", "IP-CIDR"),
            ("rule_set", "RULE-SET"), ("process_name", "PROCESS-NAME"),
            ("process_path", "PROCESS-PATH"), ("ip_is_private", "IP-PRIVATE"),
            ("clash_mode", "MODE"),
        ]
        for (k, label) in keys { if rule[k] != nil { return label } }
        return "UNKNOWN"
    }

    private static func extractValue(from rule: JSONValue) -> String {
        let matchKeys = [
            "domain_suffix", "domain", "domain_keyword", "ip_cidr",
            "process_name", "process_path", "rule_set", "clash_mode",
        ]
        for key in matchKeys {
            if let val = rule[key] {
                switch val {
                case .string(let s): return s
                case .array(let arr):
                    let items = arr.compactMap { $0.stringValue }
                    if items.count <= 3 { return items.joined(separator: ", ") }
                    return "\(items.prefix(3).joined(separator: ", ")) (+\(items.count - 3))"
                case .bool(let b): return String(b)
                default: break
                }
            }
        }
        if let ip = rule["ip_is_private"] { return "私有 IP 地址" }
        return "—"
    }
}

struct RuleOverviewItem: Identifiable {
    let id: Int
    let priority: Int
    let category: String
    let type: String
    let value: String
    let outbound: String
}

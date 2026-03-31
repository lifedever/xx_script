import SwiftUI

struct DNSRulesView: View {
    @Environment(AppState.self) private var appState

    @State private var rules: [DNSRuleItem] = []
    @State private var servers: [DNSServerItem] = []
    @State private var showAddRule = false
    @State private var showAddServer = false
    @State private var editingServerIndex: Int?
    @State private var editingRuleIndex: Int?
    @State private var deletingRuleIndex: Int?
    @State private var deletingServerIndex: Int?

    private struct EditItem: Identifiable {
        let id: Int
    }
    @State private var editItem: EditItem?
    @State private var serverEditItem: EditItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("DNS 管理")
                    .font(.title2)
                    .bold()
                Spacer()
                Button {
                    loadData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
                Button {
                    showAddRule = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加 DNS 规则")
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // DNS Servers section
                    serverSection

                    Divider()
                        .padding(.horizontal)

                    // DNS Rules section
                    rulesSection
                }
                .padding()
            }
        }
        .onAppear { loadData() }
        .sheet(isPresented: $showAddRule) {
            DNSRuleEditSheet(mode: .add, servers: servers) { rule in
                insertRule(rule)
            }
            .onDisappear { loadData() }
        }
        .sheet(item: $editItem) { item in
            let configRules = appState.configEngine.config.dns?.rules ?? []
            if item.id >= 0 && item.id < configRules.count {
                DNSRuleEditSheet(mode: .edit(index: item.id, rule: configRules[item.id]), servers: servers) { rule in
                    updateRule(at: item.id, with: rule)
                }
                .onDisappear { loadData() }
            }
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
            Text("确定要删除这条 DNS 规则吗？")
        }
        .sheet(isPresented: $showAddServer) {
            DNSServerEditSheet(mode: .add) { server in
                addServer(server)
            }
            .onDisappear { loadData() }
        }
        .sheet(item: $serverEditItem) { item in
            let rawServers = appState.configEngine.config.dns?.servers ?? []
            if item.id >= 0 && item.id < rawServers.count {
                DNSServerEditSheet(mode: .edit(index: item.id, server: rawServers[item.id])) { server in
                    updateServer(at: item.id, with: server)
                }
                .onDisappear { loadData() }
            }
        }
        .confirmationDialog("确认删除", isPresented: .init(
            get: { deletingServerIndex != nil },
            set: { if !$0 { deletingServerIndex = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let idx = deletingServerIndex { deleteServer(at: idx) }
                deletingServerIndex = nil
            }
            Button("取消", role: .cancel) { deletingServerIndex = nil }
        } message: {
            Text("确定要删除这个 DNS 服务器吗？引用它的规则将失效。")
        }
    }

    // MARK: - Server Section

    private static let systemServerTags: Set<String> = ["hosts", "dns_fakeip"]

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DNS 服务器")
                    .font(.headline)
                Spacer()
                Button {
                    showAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            // Table header
            HStack(spacing: 0) {
                Text("标签").frame(width: 120, alignment: .leading)
                Text("说明").frame(width: 160, alignment: .leading)
                Text("类型").frame(width: 80, alignment: .leading)
                Text("地址").frame(minWidth: 120, alignment: .leading)
                Spacer()
                Text("出站").frame(width: 80, alignment: .leading)
                Text("操作").frame(width: 110, alignment: .center)
            }
            .fontWeight(.bold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            LazyVStack(spacing: 0) {
                ForEach(Array(servers.enumerated()), id: \.element.tag) { index, server in
                    let isSystem = Self.systemServerTags.contains(server.tag)
                    HStack(spacing: 0) {
                        Text(server.tag)
                            .lineLimit(1)
                            .frame(width: 120, alignment: .leading)

                        Text(serverDescription(server.tag))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 160, alignment: .leading)

                        Text(server.type)
                            .monospaced()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(serverTypeColor(server.type).opacity(0.12))
                            .foregroundStyle(serverTypeColor(server.type))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .frame(width: 80, alignment: .leading)

                        Text(server.address)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(minWidth: 120, alignment: .leading)

                        Spacer()

                        Text(server.detour)
                            .foregroundStyle(.tertiary)
                            .frame(width: 80, alignment: .leading)

                        HStack(spacing: 4) {
                            if !isSystem {
                                Button("编辑") { serverEditItem = EditItem(id: index) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                Button("删除") { deletingServerIndex = index }
                                    .buttonStyle(.bordered).controlSize(.small).tint(.red)
                            }
                        }
                        .frame(width: 110, alignment: .center)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(index % 2 == 0 ? Color.clear : Color.gray.opacity(0.06))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Rules Section

    /// System DNS rule types
    private static let systemActions: Set<String> = ["reject"]
    private static let systemKeys: Set<String> = ["ip_accept_any", "clash_mode", "query_type"]

    private static func isSystemRule(_ rule: JSONValue) -> Bool {
        let action = rule["action"]?.stringValue ?? ""
        if systemActions.contains(action) { return true }
        if rule["clash_mode"] != nil { return true }
        if rule["ip_accept_any"] != nil { return true }
        if rule["query_type"] != nil { return true }
        return false
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DNS 规则")
                .font(.headline)

            Text("\(rules.count) 条规则")
                .foregroundStyle(.secondary)

            // Table header
            HStack(spacing: 0) {
                Text("#").frame(width: 30, alignment: .leading)
                Text("匹配条件").frame(width: 180, alignment: .leading)
                Text("匹配值").frame(minWidth: 200, alignment: .leading)
                Spacer()
                Text("DNS 服务器").frame(width: 120, alignment: .leading)
                Text("操作").frame(width: 110, alignment: .center)
            }
            .fontWeight(.bold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            let customRules = rules.filter { !$0.isSystem }
            let systemRules = rules.filter { $0.isSystem }

            LazyVStack(spacing: 0) {
                if !customRules.isEmpty {
                    ruleSectionHeader("自定义规则")
                    ForEach(customRules) { rule in
                        dnsRuleRow(rule)
                    }
                }
                if !systemRules.isEmpty {
                    ruleSectionHeader("系统规则")
                    ForEach(systemRules) { rule in
                        dnsRuleRow(rule)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func ruleSectionHeader(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.06))
    }

    private func dnsRuleRow(_ rule: DNSRuleItem) -> some View {
        HStack(spacing: 0) {
            Text("\(rule.index + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            ruleTypeBadge(rule.matchType)
                .frame(width: 180, alignment: .leading)

            Group {
                if rule.isSystem && rule.matchValue == "—" {
                    Text(systemDescription(rule))
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    Text(rule.matchValue)
                        .monospaced()
                }
            }
            .lineLimit(1)
            .frame(minWidth: 200, alignment: .leading)

            Spacer()

            Text(rule.server)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            HStack(spacing: 6) {
                if !rule.isSystem {
                    Button("编辑") { editItem = EditItem(id: rule.index) }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("删除") { deletingRuleIndex = rule.index }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red)
                }
            }
            .frame(width: 110, alignment: .center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(rule.index % 2 == 0 ? Color.clear : Color.gray.opacity(0.06))
    }

    // MARK: - Helpers

    private func systemDescription(_ rule: DNSRuleItem) -> String {
        switch rule.matchType {
        case "HOSTS": return "本地 hosts"
        case "MODE": return rule.matchValue
        case "FAKEIP": return "FakeIP 映射"
        case "REJECT": return "拦截广告"
        default: return "—"
        }
    }

    private func ruleTypeBadge(_ type: String) -> some View {
        Text(type)
            .monospaced()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ruleTypeColor(type).opacity(0.12))
            .foregroundStyle(ruleTypeColor(type))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func ruleTypeColor(_ type: String) -> Color {
        switch type {
        case "PROCESS-NAME": return .cyan
        case "DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD": return .blue
        case "RULE-SET": return .green
        case "REJECT": return .red
        case "HOSTS": return .mint
        case "MODE": return .indigo
        case "FAKEIP": return .purple
        default: return .secondary
        }
    }

    private func serverDescription(_ tag: String) -> String {
        switch tag {
        case "hosts": return "本地 hosts 文件解析"
        case "dns_proxy": return "海外域名，通过代理解析"
        case "dns_local": return "系统本地 DNS"
        case "dns_direct": return "国内域名，阿里 DNS 直连"
        case "dns_fakeip": return "虚拟 IP 映射，代理域名用"
        default: return "自定义 DNS 服务器"
        }
    }

    private func serverTypeColor(_ type: String) -> Color {
        switch type {
        case "https": return .green
        case "udp": return .blue
        case "local": return .orange
        case "fakeip": return .purple
        case "hosts": return .mint
        default: return .secondary
        }
    }

    // MARK: - Data

    private func loadData() {
        // Load servers
        let rawServers = appState.configEngine.config.dns?.servers ?? []
        servers = rawServers.enumerated().map { (i, s) in
            DNSServerItem(
                tag: s["tag"]?.stringValue ?? "server-\(i)",
                type: s["type"]?.stringValue ?? "unknown",
                address: s["server"]?.stringValue ?? "—",
                detour: s["detour"]?.stringValue ?? "—"
            )
        }

        // Load rules
        let rawRules = appState.configEngine.config.dns?.rules ?? []
        rules = rawRules.enumerated().map { (i, r) in
            DNSRuleItem(
                index: i,
                matchType: Self.extractType(from: r),
                matchValue: Self.extractValue(from: r),
                server: r["server"]?.stringValue ?? r["action"]?.stringValue ?? "—",
                isSystem: Self.isSystemRule(r)
            )
        }
    }

    private static func extractType(from rule: JSONValue) -> String {
        let typeKeys: [(key: String, label: String)] = [
            ("ip_accept_any", "HOSTS"),
            ("clash_mode", "MODE"),
            ("domain_suffix", "DOMAIN-SUFFIX"),
            ("domain", "DOMAIN"),
            ("domain_keyword", "DOMAIN-KEYWORD"),
            ("process_name", "PROCESS-NAME"),
            ("process_path", "PROCESS-PATH"),
            ("rule_set", "RULE-SET"),
            ("query_type", "FAKEIP"),
        ]
        for (key, label) in typeKeys {
            if rule[key] != nil { return label }
        }
        if rule["action"]?.stringValue == "reject" { return "REJECT" }
        return "UNKNOWN"
    }

    private static func extractValue(from rule: JSONValue) -> String {
        let matchKeys = [
            "domain_suffix", "domain", "domain_keyword",
            "process_name", "process_path", "rule_set",
            "clash_mode", "query_type",
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
        return "—"
    }

    private func insertRule(_ rule: JSONValue) {
        var dnsRules = appState.configEngine.config.dns?.rules ?? []
        // Insert after system rules at the top
        let systemActions: Set<String> = ["reject"]
        var insertIdx = 0
        for r in dnsRules {
            let isSystem = Self.isSystemRule(r)
            guard isSystem else { break }
            insertIdx += 1
        }
        dnsRules.insert(rule, at: insertIdx)
        appState.configEngine.config.dns?.rules = dnsRules
        do {
            try appState.configEngine.save(restartRequired: true)
        } catch {
            appState.showAlert("保存失败: \(error.localizedDescription)")
        }
        loadData()
    }

    private func updateRule(at index: Int, with rule: JSONValue) {
        var dnsRules = appState.configEngine.config.dns?.rules ?? []
        guard index >= 0 && index < dnsRules.count else { return }
        dnsRules[index] = rule
        appState.configEngine.config.dns?.rules = dnsRules
        do {
            try appState.configEngine.save(restartRequired: true)
        } catch {
            appState.showAlert("保存失败: \(error.localizedDescription)")
        }
        loadData()
    }

    private func deleteRule(at index: Int) {
        var dnsRules = appState.configEngine.config.dns?.rules ?? []
        guard index >= 0 && index < dnsRules.count else { return }
        dnsRules.remove(at: index)
        appState.configEngine.config.dns?.rules = dnsRules
        do {
            try appState.configEngine.save(restartRequired: true)
        } catch {
            appState.showAlert("删除失败: \(error.localizedDescription)")
        }
        loadData()
    }

    // MARK: - Server CRUD

    private func addServer(_ server: JSONValue) {
        var servers = appState.configEngine.config.dns?.servers ?? []
        servers.append(server)
        appState.configEngine.config.dns?.servers = servers
        do { try appState.configEngine.save(restartRequired: true) }
        catch { appState.showAlert("保存失败: \(error.localizedDescription)") }
        loadData()
    }

    private func updateServer(at index: Int, with server: JSONValue) {
        var servers = appState.configEngine.config.dns?.servers ?? []
        guard index >= 0 && index < servers.count else { return }
        servers[index] = server
        appState.configEngine.config.dns?.servers = servers
        do { try appState.configEngine.save(restartRequired: true) }
        catch { appState.showAlert("保存失败: \(error.localizedDescription)") }
        loadData()
    }

    private func deleteServer(at index: Int) {
        var servers = appState.configEngine.config.dns?.servers ?? []
        guard index >= 0 && index < servers.count else { return }
        servers.remove(at: index)
        appState.configEngine.config.dns?.servers = servers
        do { try appState.configEngine.save(restartRequired: true) }
        catch { appState.showAlert("删除失败: \(error.localizedDescription)") }
        loadData()
    }
}

// MARK: - Data Models

struct DNSServerItem: Identifiable {
    let tag: String
    let type: String
    let address: String
    let detour: String
    var id: String { tag }
}

struct DNSRuleItem: Identifiable {
    let index: Int
    let matchType: String
    let matchValue: String
    let server: String
    let isSystem: Bool
    var id: Int { index }
}

// MARK: - Edit Sheet

enum DNSRuleEditMode {
    case add
    case edit(index: Int, rule: JSONValue)
}

struct DNSRuleEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: DNSRuleEditMode
    let servers: [DNSServerItem]
    let onSave: (JSONValue) -> Void

    @State private var ruleType = "PROCESS-NAME"
    @State private var ruleValue = ""
    @State private var selectedServer = "dns_direct"
    @State private var errorMessage: String?

    private let ruleTypes = ["PROCESS-NAME", "DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD", "RULE-SET"]

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var singboxKey: String {
        switch ruleType {
        case "DOMAIN": return "domain"
        case "DOMAIN-SUFFIX": return "domain_suffix"
        case "DOMAIN-KEYWORD": return "domain_keyword"
        case "PROCESS-NAME": return "process_name"
        case "RULE-SET": return "rule_set"
        default: return "process_name"
        }
    }

    private var ruleTypeHint: String {
        switch ruleType {
        case "PROCESS-NAME": return "按进程名匹配，多个用逗号分隔"
        case "DOMAIN-SUFFIX": return "匹配域名后缀，多个用逗号分隔"
        case "DOMAIN": return "精确匹配完整域名"
        case "DOMAIN-KEYWORD": return "域名包含关键词即匹配"
        case "RULE-SET": return "引用规则集名称，多个用逗号分隔"
        default: return ""
        }
    }

    private var placeholder: String {
        switch ruleType {
        case "PROCESS-NAME": return "WeChat, QQ, DingTalk"
        case "RULE-SET": return "geosite-cn, geosite-apple-cn"
        case "DOMAIN-SUFFIX": return "qq.com, weixin.qq.com"
        case "DOMAIN": return "www.example.com"
        case "DOMAIN-KEYWORD": return "wechat, alipay"
        default: return "匹配值"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "编辑 DNS 规则" : "添加 DNS 规则").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding()

            Divider()

            Form {
                Picker("匹配类型", selection: $ruleType) {
                    ForEach(ruleTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }

                TextField("匹配值", text: $ruleValue, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                Text(ruleTypeHint)
                    .foregroundStyle(.tertiary)

                Picker("DNS 服务器", selection: $selectedServer) {
                    ForEach(servers) { server in
                        Text("\(serverLabel(server))").tag(server.tag)
                    }
                }

                Text(serverHint)
                    .foregroundStyle(.tertiary)

                // Preview
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("预览")
                            .foregroundStyle(.secondary)
                        Text("""
                        {
                          "\(singboxKey)": [\(ruleValue.split(separator: ",").map { "\"\($0.trimmingCharacters(in: .whitespaces))\"" }.joined(separator: ", "))],
                          "action": "route",
                          "server": "\(selectedServer)"
                        }
                        """)
                        .monospaced()
                        .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let err = errorMessage {
                    Text(err).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
        .onAppear {
            if case .edit(_, let rule) = mode {
                // Load existing values
                let typeMapping: [(key: String, type: String)] = [
                    ("process_name", "PROCESS-NAME"),
                    ("domain_suffix", "DOMAIN-SUFFIX"),
                    ("domain", "DOMAIN"),
                    ("domain_keyword", "DOMAIN-KEYWORD"),
                    ("rule_set", "RULE-SET"),
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
                selectedServer = rule["server"]?.stringValue ?? "dns_direct"
            }
        }
    }

    private func serverLabel(_ server: DNSServerItem) -> String {
        switch server.tag {
        case "dns_direct": return "dns_direct — 国内直连 (\(server.address))"
        case "dns_proxy": return "dns_proxy — 代理解析 (\(server.address))"
        case "dns_local": return "dns_local — 系统本地 DNS"
        case "dns_fakeip": return "dns_fakeip — FakeIP（虚拟 IP 映射）"
        case "hosts": return "hosts — 本地 hosts 文件"
        default: return "\(server.tag) (\(server.type): \(server.address))"
        }
    }

    private var serverHint: String {
        switch selectedServer {
        case "dns_direct": return "国内域名推荐，走阿里 DNS 直连解析，速度快"
        case "dns_proxy": return "海外域名推荐，通过代理走 Google DNS 解析"
        case "dns_local": return "使用系统默认 DNS 解析"
        case "dns_fakeip": return "返回虚拟 IP，用于需要代理的域名"
        case "hosts": return "匹配本地 hosts 文件"
        default: return ""
        }
    }

    private func save() {
        let trimmed = ruleValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { errorMessage = "请输入匹配值"; return }

        let values = trimmed.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let ruleDict: [String: JSONValue] = [
            singboxKey: .array(values.map { .string($0) }),
            "action": .string("route"),
            "server": .string(selectedServer),
        ]

        dismiss()
        onSave(.object(ruleDict))
    }
}

// MARK: - DNS Server Edit Sheet

enum DNSServerEditMode {
    case add
    case edit(index: Int, server: JSONValue)
}

struct DNSServerEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: DNSServerEditMode
    let onSave: (JSONValue) -> Void

    @State private var tag = ""
    @State private var serverType = "udp"
    @State private var address = ""
    @State private var detour = ""
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private let serverTypes = [
        ("udp", "UDP"),
        ("https", "HTTPS (DoH)"),
        ("tls", "TLS (DoT)"),
        ("local", "Local"),
    ]

    private var serverTypeHint: String {
        switch serverType {
        case "udp": return "传统 DNS，速度快，明文传输（如阿里 223.5.5.5）"
        case "https": return "DNS over HTTPS，加密传输（如 Google 8.8.8.8）"
        case "tls": return "DNS over TLS，加密传输"
        case "local": return "使用系统本地 DNS 解析"
        default: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "编辑 DNS 服务器" : "添加 DNS 服务器").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding()

            Divider()

            Form {
                TextField("标签", text: $tag, prompt: Text("dns_custom"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditing)

                Picker("类型", selection: $serverType) {
                    ForEach(serverTypes, id: \.0) { type in
                        Text(type.1).tag(type.0)
                    }
                }

                Text(serverTypeHint)
                    .foregroundStyle(.tertiary)

                if serverType != "local" {
                    TextField("服务器地址", text: $address, prompt: Text(serverType == "udp" ? "223.5.5.5" : "8.8.8.8"))
                        .textFieldStyle(.roundedBorder)
                        .monospaced()

                    Text(serverType == "udp" ? "UDP DNS 服务器地址" : "DoH/DoT 服务器地址")
                        .foregroundStyle(.tertiary)
                }

                TextField("出站", text: $detour, prompt: Text("留空为直连，填 Proxy 走代理"))
                    .textFieldStyle(.roundedBorder)

                if let err = errorMessage {
                    Text(err).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480, height: 380)
        .onAppear {
            if case .edit(_, let server) = mode {
                tag = server["tag"]?.stringValue ?? ""
                serverType = server["type"]?.stringValue ?? "udp"
                address = server["server"]?.stringValue ?? ""
                detour = server["detour"]?.stringValue ?? ""
            }
        }
    }

    private func save() {
        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmedTag.isEmpty else { errorMessage = "请输入标签"; return }

        var dict: [String: JSONValue] = [
            "tag": .string(trimmedTag),
            "type": .string(serverType),
        ]

        let trimmedAddr = address.trimmingCharacters(in: .whitespaces)
        if !trimmedAddr.isEmpty {
            dict["server"] = .string(trimmedAddr)
        }

        let trimmedDetour = detour.trimmingCharacters(in: .whitespaces)
        if !trimmedDetour.isEmpty {
            dict["detour"] = .string(trimmedDetour)
        }

        dismiss()
        onSave(.object(dict))
    }
}

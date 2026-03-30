import SwiftUI

struct ProxiesView: View {
    @Environment(AppState.self) private var appState

    @State private var groups: [ProxyGroup] = []
    @State private var delays: [String: Int] = [:]
    @State private var testingGroups: Set<String> = []
    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var popoverGroup: String?
    @State private var showGroupEdit = false
    @State private var editingGroupTag: String?
    @State private var deletingGroupTag: String?
    @State private var selectedGroup: String?

    // MARK: - Group Classification

    private struct ClassifiedGroups {
        var top: [ProxyGroup] = []
        var services: [ProxyGroup] = []
        var regions: [ProxyGroup] = []
        var subscriptions: [ProxyGroup] = []
    }

    private var classified: ClassifiedGroups {
        classifyGroups(filtered)
    }

    private var filtered: [ProxyGroup] {
        let selectors = groups.filter { $0.type == "Selector" || $0.type == "URLTest" }
        if searchText.isEmpty { return selectors }
        return selectors.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func classifyGroups(_ groups: [ProxyGroup]) -> ClassifiedGroups {
        let patterns = appState.configEngine.loadGroupPatterns()
        let regionGroupNames = Set(patterns.keys)
        let groupOrder = appState.configEngine.loadOrderedGroupKeys()

        var result = ClassifiedGroups()
        var classified = Set<String>()

        for group in groups {
            if group.name.hasPrefix("📦") {
                result.subscriptions.append(group)
                classified.insert(group.id)
            } else if regionGroupNames.contains(group.name) || group.name == "🌐其他" {
                result.regions.append(group)
                classified.insert(group.id)
            }
        }

        result.regions.sort { a, b in
            let ia = groupOrder.firstIndex(of: a.name) ?? Int.max
            let ib = groupOrder.firstIndex(of: b.name) ?? Int.max
            return ia < ib
        }

        let serviceNames: Set<String> = ["OpenAI", "Google", "YouTube", "Netflix",
                                          "Disney", "TikTok", "Microsoft", "Notion",
                                          "Apple", "Telegram", "Spotify", "Twitter",
                                          "GitHub", "Steam", "Twitch", "Claude",
                                          "Gemini", "ChatGPT"]
        for group in groups where !classified.contains(group.id) {
            if serviceNames.contains(where: { group.name.contains($0) }) {
                result.services.append(group)
                classified.insert(group.id)
            }
        }

        for group in groups where !classified.contains(group.id) {
            result.top.append(group)
        }

        return result
    }

    /// Flattened list of all rows for alternating background calculation
    private var allRows: [ProxyGroup] {
        var rows: [ProxyGroup] = []
        rows.append(contentsOf: classified.top)
        rows.append(contentsOf: classified.services)
        rows.append(contentsOf: classified.regions)
        rows.append(contentsOf: classified.subscriptions)
        return rows
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("策略组")
                    .font(.title2)
                    .bold()
                Spacer()
                TextField("搜索...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button {
                    Task { await refreshGroups() }
                } label: {
                    if isRefreshing {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("刷新")
                .disabled(isRefreshing)
                Button {
                    testAllGroupsLatency()
                } label: {
                    Image(systemName: "speedometer")
                }
                .help("测速全部")
                Button {
                    editingGroupTag = nil
                    showGroupEdit = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建策略组")
            }
            .padding()

            Divider()

            if groups.isEmpty && !isRefreshing {
                ContentUnavailableView {
                    Label("No proxy groups", systemImage: "network.slash")
                } description: {
                    Text("sing-box is not running or Clash API is unreachable")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(filtered.count) 个策略组")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if filtered.isEmpty {
                            Text("暂无策略组")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                        } else {
                            // Table header
                            HStack(spacing: 0) {
                                Text("名称")
                                    .frame(width: 180, alignment: .leading)
                                Text("类型")
                                    .frame(width: 80, alignment: .leading)
                                Text("当前节点")
                                    .frame(minWidth: 200, alignment: .leading)
                                Spacer()
                                Text("节点数")
                                    .frame(width: 60, alignment: .center)
                                Text("操作")
                                    .frame(width: 100, alignment: .center)
                            }
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)

                            LazyVStack(spacing: 0) {
                                // Top-level groups
                                ForEach(classified.top) { group in
                                    groupRow(group)
                                }

                                // Services section
                                if !classified.services.isEmpty {
                                    tableSectionHeader("服务分流")
                                    ForEach(classified.services) { group in
                                        groupRow(group)
                                    }
                                }

                                // Regions section
                                if !classified.regions.isEmpty {
                                    tableSectionHeader("地区节点")
                                    ForEach(classified.regions) { group in
                                        groupRow(group)
                                    }
                                }

                                // Subscriptions section
                                if !classified.subscriptions.isEmpty {
                                    tableSectionHeader("订阅分组")
                                    ForEach(classified.subscriptions) { group in
                                        groupRow(group)
                                    }
                                }
                            }
                            .background(Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding()
                }
            }
        }
        .task {
            await refreshGroups()
        }
        .sheet(isPresented: $showGroupEdit) {
            ProxyGroupEditSheet(existingTag: editingGroupTag)
        }
        .alert("确认删除", isPresented: .init(
            get: { deletingGroupTag != nil },
            set: { if !$0 { deletingGroupTag = nil } }
        )) {
            Button("取消", role: .cancel) { deletingGroupTag = nil }
            Button("删除", role: .destructive) {
                if let tag = deletingGroupTag {
                    deleteGroup(tag)
                }
                deletingGroupTag = nil
            }
        } message: {
            Text("确定要删除策略组「\(deletingGroupTag ?? "")」吗？")
        }
    }

    // MARK: - Table Components

    private func tableSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.06))
    }

    private var regionGroupNames: Set<String> {
        Set(appState.configEngine.loadGroupPatterns().keys)
    }

    private func groupRow(_ group: ProxyGroup) -> some View {
        let rowIndex = allRows.firstIndex(where: { $0.id == group.id }) ?? 0
        let isSelected = selectedGroup == group.name
        let isRegionGroup = regionGroupNames.contains(group.name) || group.name == "🌐其他"
        let isSystemGroup = group.name == "Proxy" || group.name.contains("漏网之鱼")
        let canDelete = !isRegionGroup && !isSystemGroup

        return HStack(spacing: 0) {
            // Name + description
            VStack(alignment: .leading, spacing: 0) {
                Text(group.name)
                    .font(.body)
                    .lineLimit(1)
                if group.name == "Proxy" {
                    Text("默认出站代理组")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if group.name.contains("漏网之鱼") {
                    Text("未匹配规则的流量 (final)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 180, alignment: .leading)

            // Type badge
            typeBadge(for: group)
                .frame(width: 80, alignment: .leading)

            // Current node + delay (read-only display)
            HStack(spacing: 6) {
                if let now = group.now, !now.isEmpty {
                    Circle()
                        .fill(delayDotColor(for: group))
                        .frame(width: 6, height: 6)
                    Text(now)
                        .font(.body)
                        .lineLimit(1)
                    if let d = delays[now], d > 0 {
                        Text("\(d)ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(delayColor(d))
                    }
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 200, alignment: .leading)

            Spacer()

            // Node count
            Text("\(group.displayAll.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .center)

            // 操作按钮
            HStack(spacing: 6) {
                if !isRegionGroup {
                    Button("编辑") {
                        editingGroupTag = group.name
                        showGroupEdit = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if canDelete {
                    Button("删除") {
                        deletingGroupTag = group.name
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
                : (rowIndex % 2 == 0 ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Color.gray.opacity(0.06)))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedGroup = (selectedGroup == group.name) ? nil : group.name
        }
        .contextMenu {
            if !isRegionGroup {
                Button("编辑") { editingGroupTag = group.name; showGroupEdit = true }
            }
            if canDelete {
                Button("删除", role: .destructive) { deletingGroupTag = group.name }
            }
        }
    }

    // MARK: - Badge & Color Helpers

    private func typeBadge(for group: ProxyGroup) -> some View {
        let text: String
        let color: Color
        switch group.type.lowercased() {
        case "selector":
            text = "select"
            color = .blue
        case "urltest", "url-test":
            text = "url-test"
            color = .green
        case "fallback":
            text = "fallback"
            color = .orange
        default:
            text = group.type.lowercased()
            color = .secondary
        }
        return Text(text)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func delayDotColor(for group: ProxyGroup) -> Color {
        guard let now = group.now, let d = delays[now], d > 0 else { return .gray }
        return delayColor(d)
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay < 150 { return .green }
        if delay <= 300 { return .yellow }
        return .red
    }

    // MARK: - Actions

    private func refreshGroups() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let apiGroups = (try? await appState.api.getProxies()) ?? []
        let apiMap = Dictionary(apiGroups.map { ($0.name, $0) }, uniquingKeysWith: { $1 })

        // Merge: ConfigEngine groups (source of truth) + Clash API runtime state
        var result: [ProxyGroup] = []
        for outbound in appState.configEngine.config.outbounds {
            switch outbound {
            case .selector(let s):
                if let api = apiMap[s.tag] {
                    result.append(api)
                } else {
                    result.append(ProxyGroup(name: s.tag, type: "Selector", now: s.default, all: s.outbounds))
                }
            case .urltest(let u):
                if let api = apiMap[u.tag] {
                    result.append(api)
                } else {
                    result.append(ProxyGroup(name: u.tag, type: "URLTest", now: nil, all: u.outbounds))
                }
            default: break
            }
        }
        for api in apiGroups where !result.contains(where: { $0.name == api.name }) {
            result.append(api)
        }
        groups = result
    }

    private func selectNode(group: String, node: String) {
        Task {
            try? await appState.api.selectProxy(group: group, name: node)
            await refreshGroups()
        }
    }

    private func deleteGroup(_ tag: String) {
        appState.configEngine.config.outbounds.removeAll { $0.tag == tag }
        try? appState.configEngine.save(restartRequired: true)
        Task { await refreshGroups() }
    }

    private func testAllGroupsLatency() {
        for group in groups {
            testGroupLatency(group)
        }
    }

    private func testGroupLatency(_ group: ProxyGroup) {
        Task {
            testingGroups.insert(group.name)
            defer { testingGroups.remove(group.name) }
            await withTaskGroup(of: (String, Int).self) { taskGroup in
                for node in group.displayAll {
                    taskGroup.addTask {
                        let d = (try? await appState.api.getDelay(name: node)) ?? 0
                        return (node, d)
                    }
                }
                for await (node, delay) in taskGroup {
                    delays[node] = delay
                }
            }
        }
    }
}

// MARK: - Node Selection Popover

private struct NodeSelectionPopover: View {
    let group: ProxyGroup
    let delays: [String: Int]
    let onSelect: (String) -> Void
    @State private var searchText = ""

    var filteredNodes: [String] {
        if searchText.isEmpty { return group.displayAll }
        return group.displayAll.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with group name
            HStack {
                Text(group.name).font(.headline)
                Spacer()
                Text(group.type.lowercased())
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search
            TextField("搜索节点...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            Divider()

            // Node list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredNodes, id: \.self) { node in
                        Button {
                            onSelect(node)
                        } label: {
                            HStack(spacing: 8) {
                                if node == group.now {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.quaternary)
                                        .font(.caption)
                                }
                                Text(node)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                                if let d = delays[node], d > 0 {
                                    DelayBadge(delay: d)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(node == group.now ? Color.accentColor.opacity(0.08) : Color.clear)
                    }
                }
            }
        }
    }
}

// MARK: - Delay Badge

struct DelayBadge: View {
    let delay: Int

    var body: some View {
        Text(delay > 0 ? "\(delay)ms" : "timeout")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var color: Color {
        if delay <= 0 { return .red }
        if delay < 150 { return .green }
        if delay <= 300 { return .yellow }
        return .orange
    }
}

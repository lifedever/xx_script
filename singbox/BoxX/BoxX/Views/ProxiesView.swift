import SwiftUI

struct ProxiesView: View {
    @Environment(AppState.self) private var appState

    @State private var groups: [ProxyGroup] = []
    @State private var delays: [String: Int] = [:]
    @State private var testingGroups: Set<String> = []
    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var popoverGroup: String?

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
        let selectors = groups.filter { $0.type == "Selector" }
        if searchText.isEmpty { return selectors }
        return selectors.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func classifyGroups(_ groups: [ProxyGroup]) -> ClassifiedGroups {
        let serviceNames: Set<String> = ["OpenAI", "Google", "YouTube", "Netflix",
                                          "Disney", "TikTok", "Microsoft", "Notion",
                                          "Apple", "Telegram", "Spotify", "Twitter",
                                          "GitHub", "Steam", "Twitch", "Claude",
                                          "Gemini", "ChatGPT"]
        let regionPrefixes = ["🇭🇰", "🇨🇳", "🇯🇵", "🇰🇷", "🇸🇬", "🇺🇸", "🇬🇧", "🇩🇪", "🇫🇷", "🇦🇺", "🇨🇦", "🇹🇼", "🌍"]
        let regionNames = ["香港", "日本", "韩国", "新加坡", "美国", "英国", "德国", "法国", "澳大利亚", "加拿大", "台湾"]

        var result = ClassifiedGroups()
        var classified = Set<String>()

        for group in groups {
            if group.name.hasPrefix("📦") {
                result.subscriptions.append(group)
                classified.insert(group.id)
            } else if regionPrefixes.contains(where: { group.name.hasPrefix($0) })
                        || regionNames.contains(where: { group.name.contains($0) }) {
                result.regions.append(group)
                classified.insert(group.id)
            } else if serviceNames.contains(where: { group.name.contains($0) }) {
                result.services.append(group)
                classified.insert(group.id)
            }
        }

        // Everything else goes to top (like "Proxy")
        for group in groups where !classified.contains(group.id) {
            result.top.append(group)
        }

        return result
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "proxies.search"), text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    Task { await refreshGroups() }
                } label: {
                    if isRefreshing {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if groups.isEmpty && !isRefreshing {
                ContentUnavailableView {
                    Label("No proxy groups", systemImage: "network.slash")
                } description: {
                    Text("sing-box is not running or Clash API is unreachable")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Top-level groups (e.g. "Proxy") - full width cards
                        if !classified.top.isEmpty {
                            ForEach(classified.top) { group in
                                ProxyGroupCard(
                                    group: group,
                                    delays: delays,
                                    isTesting: testingGroups.contains(group.name),
                                    showPopover: Binding(
                                        get: { popoverGroup == group.name },
                                        set: { newVal in popoverGroup = newVal ? group.name : nil }
                                    ),
                                    onSelect: { node in selectNode(group: group.name, node: node) },
                                    onTest: { testGroupLatency(group) }
                                )
                            }
                        }

                        // Services section
                        if !classified.services.isEmpty {
                            sectionHeader(
                                String(localized: "proxies.section.services"),
                                icon: "arrow.triangle.branch"
                            )
                            LazyVGrid(columns: gridColumns, spacing: 10) {
                                ForEach(classified.services) { group in
                                    ProxyGroupCard(
                                        group: group,
                                        delays: delays,
                                        isTesting: testingGroups.contains(group.name),
                                        showPopover: Binding(
                                            get: { popoverGroup == group.name },
                                            set: { newVal in popoverGroup = newVal ? group.name : nil }
                                        ),
                                        onSelect: { node in selectNode(group: group.name, node: node) },
                                        onTest: { testGroupLatency(group) }
                                    )
                                }
                            }
                        }

                        // Regions section
                        if !classified.regions.isEmpty {
                            sectionHeader(
                                String(localized: "proxies.section.regions"),
                                icon: "globe"
                            )
                            LazyVGrid(columns: gridColumns, spacing: 10) {
                                ForEach(classified.regions) { group in
                                    ProxyGroupCard(
                                        group: group,
                                        delays: delays,
                                        isTesting: testingGroups.contains(group.name),
                                        showPopover: Binding(
                                            get: { popoverGroup == group.name },
                                            set: { newVal in popoverGroup = newVal ? group.name : nil }
                                        ),
                                        onSelect: { node in selectNode(group: group.name, node: node) },
                                        onTest: { testGroupLatency(group) }
                                    )
                                }
                            }
                        }

                        // Subscriptions section
                        if !classified.subscriptions.isEmpty {
                            sectionHeader(
                                String(localized: "proxies.section.subscriptions"),
                                icon: "shippingbox"
                            )
                            LazyVGrid(columns: gridColumns, spacing: 10) {
                                ForEach(classified.subscriptions) { group in
                                    ProxyGroupCard(
                                        group: group,
                                        delays: delays,
                                        isTesting: testingGroups.contains(group.name),
                                        showPopover: Binding(
                                            get: { popoverGroup == group.name },
                                            set: { newVal in popoverGroup = newVal ? group.name : nil }
                                        ),
                                        onSelect: { node in selectNode(group: group.name, node: node) },
                                        onTest: { testGroupLatency(group) }
                                    )
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .task {
            await refreshGroups()
        }
    }

    // MARK: - Helpers

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func refreshGroups() async {
        isRefreshing = true
        defer { isRefreshing = false }
        groups = (try? await appState.api.getProxies()) ?? []
    }

    private func selectNode(group: String, node: String) {
        Task {
            try? await appState.api.selectProxy(group: group, name: node)
            await refreshGroups()
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

// MARK: - Proxy Group Card

private struct ProxyGroupCard: View {
    let group: ProxyGroup
    let delays: [String: Int]
    let isTesting: Bool
    @Binding var showPopover: Bool
    let onSelect: (String) -> Void
    let onTest: () -> Void

    private var currentDelay: Int? {
        guard let now = group.now else { return nil }
        return delays[now]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: name + type badge
            HStack(spacing: 8) {
                Text(group.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Spacer()

                // Type badge
                Text(typeBadgeText)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(typeBadgeColor.opacity(0.12))
                    .foregroundStyle(typeBadgeColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            // Bottom row: current node + delay + count
            HStack(spacing: 6) {
                // Delay dot
                Circle()
                    .fill(delayDotColor)
                    .frame(width: 6, height: 6)

                if let now = group.now, !now.isEmpty {
                    Text(now)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let d = currentDelay, d > 0 {
                        Text("\(d)ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(delayColor(d))
                    }
                }

                Spacer()

                // Node count
                Text("\(group.displayAll.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Image(systemName: "circle.grid.2x2")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // Test button
                Button(action: onTest) {
                    if isTesting {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "speedometer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
            }
        }
        .padding(10)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { showPopover.toggle() }
        .popover(isPresented: $showPopover) {
            NodeSelectionPopover(group: group, delays: delays, onSelect: { node in
                onSelect(node)
                showPopover = false
            })
            .frame(width: 280, height: 400)
        }
    }

    // MARK: - Badge Helpers

    private var typeBadgeText: String {
        switch group.type.lowercased() {
        case "selector": return "select"
        case "urltest", "url-test": return "url-test"
        case "fallback": return "fallback"
        default: return group.type.lowercased()
        }
    }

    private var typeBadgeColor: Color {
        switch group.type.lowercased() {
        case "selector": return .blue
        case "urltest", "url-test": return .green
        case "fallback": return .orange
        default: return .secondary
        }
    }

    private var delayDotColor: Color {
        guard let d = currentDelay, d > 0 else { return .gray }
        return delayColor(d)
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay < 150 { return .green }
        if delay <= 300 { return .yellow }
        return .red
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

import SwiftUI

struct ProxiesView: View {
    let api: ClashAPI

    @State private var groups: [ProxyGroup] = []
    @State private var delays: [String: Int] = [:]
    @State private var testingGroups: Set<String> = []
    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var expandedGroup: String?

    // Categorize groups
    private var serviceGroups: [ProxyGroup] {
        let serviceNames: Set<String> = ["Proxy", "OpenAI", "Google", "YouTube", "Netflix",
                                          "Disney", "TikTok", "Microsoft", "Notion", "Apple"]
        return filtered.filter { g in
            serviceNames.contains(where: { g.name.contains($0) })
        }
    }

    private var regionGroups: [ProxyGroup] {
        let regionPrefixes = ["🇭🇰", "🇨🇳", "🇯🇵", "🇰🇷", "🇸🇬", "🇺🇸", "🌍"]
        return filtered.filter { g in
            regionPrefixes.contains(where: { g.name.hasPrefix($0) })
        }
    }

    private var subscriptionGroups: [ProxyGroup] {
        return filtered.filter { $0.name.hasPrefix("📦") }
    }

    private var otherGroups: [ProxyGroup] {
        let known = Set(serviceGroups.map(\.id) + regionGroups.map(\.id) + subscriptionGroups.map(\.id))
        return filtered.filter { !known.contains($0.id) }
    }

    private var filtered: [ProxyGroup] {
        let selectors = groups.filter { $0.type == "Selector" }
        if searchText.isEmpty { return selectors }
        return selectors.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

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
                    VStack(spacing: 16) {
                        if !serviceGroups.isEmpty {
                            ProxySection(
                                title: String(localized: "proxies.section.services"),
                                icon: "arrow.triangle.branch",
                                groups: serviceGroups,
                                delays: delays,
                                testingGroups: testingGroups,
                                expandedGroup: $expandedGroup,
                                onSelect: selectNode,
                                onTest: testGroupLatency
                            )
                        }
                        if !regionGroups.isEmpty {
                            ProxySection(
                                title: String(localized: "proxies.section.regions"),
                                icon: "globe",
                                groups: regionGroups,
                                delays: delays,
                                testingGroups: testingGroups,
                                expandedGroup: $expandedGroup,
                                onSelect: selectNode,
                                onTest: testGroupLatency
                            )
                        }
                        if !subscriptionGroups.isEmpty {
                            ProxySection(
                                title: String(localized: "proxies.section.subscriptions"),
                                icon: "shippingbox",
                                groups: subscriptionGroups,
                                delays: delays,
                                testingGroups: testingGroups,
                                expandedGroup: $expandedGroup,
                                onSelect: selectNode,
                                onTest: testGroupLatency
                            )
                        }
                        if !otherGroups.isEmpty {
                            ProxySection(
                                title: String(localized: "proxies.section.other"),
                                icon: "ellipsis.circle",
                                groups: otherGroups,
                                delays: delays,
                                testingGroups: testingGroups,
                                expandedGroup: $expandedGroup,
                                onSelect: selectNode,
                                onTest: testGroupLatency
                            )
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

    private func refreshGroups() async {
        isRefreshing = true
        defer { isRefreshing = false }
        groups = (try? await api.getProxies()) ?? []
    }

    private func selectNode(group: String, node: String) {
        Task {
            try? await api.selectProxy(group: group, name: node)
            await refreshGroups()
        }
    }

    private func testGroupLatency(group: ProxyGroup) {
        Task {
            testingGroups.insert(group.name)
            defer { testingGroups.remove(group.name) }
            await withTaskGroup(of: (String, Int).self) { taskGroup in
                for node in group.displayAll {
                    taskGroup.addTask {
                        ((try? await api.getDelay(name: node)) ?? 0, 0).0
                        let d = (try? await api.getDelay(name: node)) ?? 0
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

// MARK: - Section

struct ProxySection: View {
    let title: String
    let icon: String
    let groups: [ProxyGroup]
    let delays: [String: Int]
    let testingGroups: Set<String>
    @Binding var expandedGroup: String?
    let onSelect: (String, String) -> Void
    let onTest: (ProxyGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            // Groups
            VStack(spacing: 1) {
                ForEach(groups) { group in
                    ProxyGroupRow(
                        group: group,
                        delays: delays,
                        isTesting: testingGroups.contains(group.name),
                        isExpanded: expandedGroup == group.name,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedGroup = expandedGroup == group.name ? nil : group.name
                            }
                        },
                        onSelect: { node in onSelect(group.name, node) },
                        onTest: { onTest(group) }
                    )
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Group Row

struct ProxyGroupRow: View {
    let group: ProxyGroup
    let delays: [String: Int]
    let isTesting: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSelect: (String) -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 10) {
                // Expand arrow
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                // Group name
                Text(group.name)
                    .font(.body)
                    .lineLimit(1)

                Spacer()

                // Current selection + delay
                if let now = group.now, !now.isEmpty {
                    HStack(spacing: 6) {
                        if let d = delays[now], d > 0 {
                            DelayBadge(delay: d)
                        }
                        Text(now)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Test button
                Button(action: onTest) {
                    if isTesting {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "speedometer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            // Expanded nodes
            if isExpanded {
                Divider().padding(.leading, 12)

                VStack(spacing: 0) {
                    ForEach(group.displayAll, id: \.self) { node in
                        HStack(spacing: 8) {
                            Image(systemName: group.now == node ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(group.now == node ? Color.accentColor : Color.secondary.opacity(0.4))

                            Text(node)
                                .font(.subheadline)
                                .lineLimit(1)

                            Spacer()

                            if let d = delays[node] {
                                DelayBadge(delay: d)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(group.now == node ? Color.accentColor.opacity(0.06) : Color.clear)
                        .onTapGesture { onSelect(node) }
                    }
                }
                .padding(.bottom, 4)
            }

            // Separator between groups
            if !isExpanded {
                Divider().padding(.leading, 32)
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
        if delay < 200 { return .green }
        if delay < 500 { return .yellow }
        return .orange
    }
}

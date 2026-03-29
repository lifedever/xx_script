import SwiftUI

struct ProxiesView: View {
    let api: ClashAPI

    @State private var groups: [ProxyGroup] = []
    @State private var delays: [String: Int] = [:]
    @State private var testingGroups: Set<String> = []
    @State private var searchText = ""
    @State private var isRefreshing = false

    var filteredGroups: [ProxyGroup] {
        let list = groups.filter { $0.type == "Selector" }
        if searchText.isEmpty { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "proxies.search"), text: $searchText)
                    .textFieldStyle(.plain)
                Spacer()
                Button {
                    Task { await refreshGroups() }
                } label: {
                    if isRefreshing {
                        ProgressView().scaleEffect(0.8)
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
                VStack(spacing: 12) {
                    Image(systemName: "network.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No proxy groups available")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredGroups) { group in
                        ProxyGroupSection(
                            group: group,
                            delays: delays,
                            isTesting: testingGroups.contains(group.name),
                            onSelect: { node in
                                Task { await selectNode(group: group.name, node: node) }
                            },
                            onTestLatency: {
                                Task { await testGroupLatency(group: group) }
                            }
                        )
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .task {
            await refreshGroups()
        }
    }

    private func refreshGroups() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            groups = try await api.getProxies()
        } catch {
            // silently ignore
        }
    }

    private func selectNode(group: String, node: String) async {
        try? await api.selectProxy(group: group, name: node)
        await refreshGroups()
    }

    private func testGroupLatency(group: ProxyGroup) async {
        testingGroups.insert(group.name)
        defer { testingGroups.remove(group.name) }

        await withTaskGroup(of: (String, Int).self) { taskGroup in
            for node in group.displayAll {
                taskGroup.addTask {
                    let delay = (try? await api.getDelay(name: node)) ?? 0
                    return (node, delay)
                }
            }
            for await (node, delay) in taskGroup {
                delays[node] = delay
            }
        }
    }
}

// MARK: - Group Section

struct ProxyGroupSection: View {
    let group: ProxyGroup
    let delays: [String: Int]
    let isTesting: Bool
    let onSelect: (String) -> Void
    let onTestLatency: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.displayAll, id: \.self) { node in
                ProxyNodeRow(
                    name: node,
                    isSelected: group.now == node,
                    delay: delays[node],
                    onSelect: { onSelect(node) }
                )
            }
        } label: {
            HStack(spacing: 10) {
                // Group name
                Text(group.name)
                    .font(.headline)

                // Type badge
                Text(group.type)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())

                Spacer()

                // Current selection
                if let now = group.now, !now.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(now)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let d = delays[now], d > 0 {
                            Text("\(d) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(delayColor(d))
                        }
                    }
                }

                // Test latency button
                Button {
                    onTestLatency()
                } label: {
                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "speedometer")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
            }
            .padding(.vertical, 2)
        }
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .red }
        if delay < 200 { return .green }
        if delay < 500 { return .yellow }
        return .orange
    }
}

// MARK: - Node Row

struct ProxyNodeRow: View {
    let name: String
    let isSelected: Bool
    let delay: Int?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.green : Color.secondary)
                    .font(.subheadline)

                Text(name)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                if let d = delay {
                    Text(d > 0 ? "\(d) ms" : String(localized: "proxies.timeout"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(d <= 0 ? .red : d < 200 ? .green : d < 500 ? .yellow : .orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}

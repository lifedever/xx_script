import SwiftUI

struct ProxiesView: View {
    let api: ClashAPI

    @State private var groups: [ProxyGroup] = []
    @State private var delays: [String: Int] = [:]
    @State private var testingGroups: Set<String> = []
    @State private var searchText = ""
    @State private var isRefreshing = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var filteredGroups: [ProxyGroup] {
        if searchText.isEmpty { return groups }
        return groups.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredGroups) { group in
                            ProxyGroupCard(
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
        do {
            groups = try await api.getProxies()
        } catch {
            // silently ignore
        }
    }

    private func selectNode(group: String, node: String) async {
        do {
            try await api.selectProxy(group: group, name: node)
            await refreshGroups()
        } catch {
            // silently ignore
        }
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

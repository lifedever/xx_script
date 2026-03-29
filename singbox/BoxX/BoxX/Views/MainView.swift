import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case proxies = "Proxies"
    case rules = "Rules"
    case connections = "Connections"
    case logs = "Logs"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.doc.horizontal"
        case .proxies: return "network"
        case .rules: return "list.bullet"
        case .connections: return "link"
        case .logs: return "doc.text"
        }
    }
}

struct MainView: View {
    let api: ClashAPI
    let singBoxManager: SingBoxManager
    let configGenerator: ConfigGenerator

    @State private var selectedItem: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            if let item = selectedItem {
                switch item {
                case .overview:
                    OverviewView(api: api, singBoxManager: singBoxManager)
                        .navigationTitle("Overview")
                case .proxies:
                    ProxiesView(api: api)
                        .navigationTitle("Proxies")
                case .rules:
                    RulesView(api: api)
                        .navigationTitle("Rules")
                case .connections:
                    ConnectionsView(api: api)
                        .navigationTitle("Connections")
                case .logs:
                    LogsView()
                        .navigationTitle("Logs")
                }
            } else {
                Text("Select a section")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

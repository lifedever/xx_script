import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case proxies
    case rules
    case connections
    case logs

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .overview: return String(localized: "sidebar.overview")
        case .proxies: return String(localized: "sidebar.proxies")
        case .rules: return String(localized: "sidebar.rules")
        case .connections: return String(localized: "sidebar.connections")
        case .logs: return String(localized: "sidebar.logs")
        }
    }

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
                Label(item.localizedTitle, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            if let item = selectedItem {
                switch item {
                case .overview:
                    OverviewView(api: api, singBoxManager: singBoxManager, configGenerator: configGenerator)
                        .navigationTitle(String(localized: "sidebar.overview"))
                case .proxies:
                    ProxiesView(api: api)
                        .navigationTitle(String(localized: "sidebar.proxies"))
                case .rules:
                    RulesView(api: api)
                        .navigationTitle(String(localized: "sidebar.rules"))
                case .connections:
                    ConnectionsView(api: api)
                        .navigationTitle(String(localized: "sidebar.connections"))
                case .logs:
                    LogsView()
                        .navigationTitle(String(localized: "sidebar.logs"))
                }
            } else {
                Text("Select a section")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

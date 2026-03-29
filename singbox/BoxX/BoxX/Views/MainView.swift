import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case proxies
    case ruleTest
    case rules
    case connections
    case logs
    case servicesConfig
    case subscriptions

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .overview: return String(localized: "sidebar.overview")
        case .proxies: return String(localized: "sidebar.proxies")
        case .ruleTest: return String(localized: "sidebar.rule_test")
        case .rules: return String(localized: "sidebar.rules")
        case .connections: return String(localized: "sidebar.connections")
        case .logs: return String(localized: "sidebar.logs")
        case .servicesConfig: return String(localized: "sidebar.services_config")
        case .subscriptions: return String(localized: "sidebar.subscriptions")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.doc.horizontal"
        case .proxies: return "network"
        case .ruleTest: return "arrow.triangle.branch"
        case .rules: return "list.bullet"
        case .connections: return "link"
        case .logs: return "doc.text"
        case .servicesConfig: return "slider.horizontal.3"
        case .subscriptions: return "antenna.radiowaves.left.and.right"
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var appState
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
                    OverviewView()
                        .environment(appState)
                        .navigationTitle(String(localized: "sidebar.overview"))
                case .proxies:
                    ProxiesView()
                        .environment(appState)
                        .navigationTitle(String(localized: "sidebar.proxies"))
                case .ruleTest:
                    RuleTestView()
                        .environment(appState)
                        .navigationTitle(String(localized: "sidebar.rule_test"))
                case .rules:
                    RulesView()
                        .environment(appState)
                        .navigationTitle(String(localized: "sidebar.rules"))
                case .connections:
                    ConnectionsView()
                        .environment(appState)
                        .navigationTitle(String(localized: "sidebar.connections"))
                case .logs:
                    LogsView()
                        .navigationTitle(String(localized: "sidebar.logs"))
                case .servicesConfig:
                    ServicesConfigView()
                        .environment(appState)
                        .navigationTitle(String(localized: "sidebar.services_config"))
                case .subscriptions:
                    SubscriptionsView()
                        .environment(appState)
                        .navigationTitle(String(localized: "sidebar.subscriptions"))
                }
            } else {
                Text("Select a section")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

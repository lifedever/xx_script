import SwiftUI

enum SidebarTab: String, CaseIterable {
    case overview = "概览"
    case proxies = "策略组"
    case routeRules = "路由规则"
    case ruleSets = "规则集"
    case builtinRules = "内置规则"
    case connections = "请求"
    case logs = "日志"
    case subscriptions = "订阅"
    case settings = "设置"

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .proxies: return "network"
        case .routeRules: return "list.bullet.rectangle"
        case .ruleSets: return "tray.2"
        case .builtinRules: return "shield.checkered"
        case .connections: return "arrow.left.arrow.right"
        case .logs: return "doc.text"
        case .subscriptions: return "antenna.radiowaves.left.and.right"
        case .settings: return "gearshape"
        }
    }

    var section: String? {
        switch self {
        case .routeRules, .ruleSets, .builtinRules: return "规则"
        default: return nil
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: SidebarTab = .overview

    private var generalTabs: [SidebarTab] { [.overview, .proxies] }
    private var ruleTabs: [SidebarTab] { [.routeRules, .ruleSets, .builtinRules] }
    private var monitorTabs: [SidebarTab] { [.connections, .logs] }
    private var manageTabs: [SidebarTab] { [.subscriptions, .settings] }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(generalTabs, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }

                Section("规则") {
                    ForEach(ruleTabs, id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }

                Section("监控") {
                    ForEach(monitorTabs, id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }

                Section("管理") {
                    ForEach(manageTabs, id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            switch selectedTab {
            case .overview:
                OverviewView()
            case .proxies:
                ProxiesView()
            case .routeRules:
                RouteRulesView()
            case .ruleSets:
                RuleSetsView()
            case .builtinRules:
                BuiltinRulesView()
            case .connections:
                ConnectionsView()
            case .logs:
                LogsView()
            case .subscriptions:
                SubscriptionsView()
            case .settings:
                SettingsView()
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

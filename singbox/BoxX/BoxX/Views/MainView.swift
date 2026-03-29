import SwiftUI

enum SidebarTab: String, CaseIterable {
    case overview = "概览"
    case proxies = "策略组"
    case rules = "规则"
    case connections = "请求"
    case logs = "日志"
    case subscriptions = "订阅"
    case settings = "设置"

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .proxies: return "network"
        case .rules: return "list.bullet.rectangle"
        case .connections: return "arrow.left.arrow.right"
        case .logs: return "doc.text"
        case .subscriptions: return "antenna.radiowaves.left.and.right"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: SidebarTab = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            switch selectedTab {
            case .overview:
                OverviewView()
            case .proxies:
                ProxiesView()
            case .rules:
                RulesView()
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

import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "概览"
    case proxyGroups = "策略组"
    case nodes = "节点列表"
    case speedTest = "测速"
    case log = "日志"
    case subscription = "订阅"
    case settings = "设置"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .proxyGroups: "arrow.triangle.branch"
        case .nodes: "server.rack"
        case .speedTest: "bolt.horizontal"
        case .log: "doc.text"
        case .subscription: "arrow.clockwise.circle"
        case .settings: "gearshape"
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var selectedItem: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedItem) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selectedItem {
            case .overview: OverviewView(viewModel: viewModel)
            case .proxyGroups: ProxyGroupsView(viewModel: viewModel)
            case .nodes: NodeListView(viewModel: viewModel)
            case .speedTest: SpeedTestView(viewModel: viewModel)
            case .log: LogView(viewModel: viewModel)
            case .subscription: SubscriptionView(viewModel: viewModel)
            case .settings: SettingsView(viewModel: viewModel)
            case .none: Text("选择一个页面").foregroundStyle(.secondary)
            }
        }
    }
}

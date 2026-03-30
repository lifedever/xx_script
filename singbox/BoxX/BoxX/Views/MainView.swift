import SwiftUI

enum SidebarTab: String, CaseIterable {
    case overview = "概览"
    case proxies = "策略组"
    case routeRules = "路由规则"
    case ruleSets = "规则集"
    case builtinRules = "内置规则"
    case ruleTest = "规则测试"
    case subscriptions = "订阅"
    case settings = "设置"

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .proxies: return "network"
        case .routeRules: return "list.bullet.rectangle"
        case .ruleSets: return "tray.2"
        case .builtinRules: return "shield.checkered"
        case .ruleTest: return "target"
        case .regionGroups: return "globe"
        case .subscriptions: return "antenna.radiowaves.left.and.right"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab: SidebarTab = .overview

    private var generalTabs: [SidebarTab] { [.overview, .proxies] }
    private var ruleTabs: [SidebarTab] { [.routeRules, .ruleSets, .builtinRules, .ruleTest] }
    private var manageTabs: [SidebarTab] { [.regionGroups, .subscriptions, .settings] }

    @State private var isApplying = false

    var body: some View {
        VStack(spacing: 0) {
            // Pending reload banner
            if appState.pendingReload && appState.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                    Text("配置已更新，点击应用后生效（约 1-2 秒短暂断网）")
                        .font(.caption)
                    Spacer()
                    if isApplying {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("应用配置") {
                            isApplying = true
                            Task {
                                await appState.applyConfig()
                                isApplying = false
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                    Button {
                        appState.pendingReload = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))

                Divider()
            }

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

                Section("管理") {
                    ForEach(manageTabs, id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }

                Section {
                    Label("监控", systemImage: "waveform.badge.magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { openWindow(id: "monitor") }
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
            case .ruleTest:
                RuleTestView()
            case .regionGroups:
                RegionGroupsView()
            case .subscriptions:
                SubscriptionsView()
            case .settings:
                SettingsView()
            }
        }
        .frame(minWidth: 800, minHeight: 500)

        } // end VStack
        .onReceive(NotificationCenter.default.publisher(for: .openMonitorWindow)) { _ in
            openWindow(id: "monitor")
        }
        .onReceive(NotificationCenter.default.publisher(for: .subscriptionLogStart)) { _ in
            openWindow(id: "update-log")
        }
    }
}

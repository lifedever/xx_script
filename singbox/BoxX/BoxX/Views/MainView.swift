import SwiftUI

enum SidebarTab: String, CaseIterable {
    case overview = "概览"
    case proxies = "策略组"
    case ruleOverview = "规则总览"
    case routeRules = "路由规则"
    case dnsRules = "DNS 管理"
    case ruleSets = "规则集"
    case builtinRules = "服务分流"
    case ruleTest = "规则测试"
    case regionGroups = "地区分组"
    case subscriptions = "订阅"
    case settings = "设置"

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .proxies: return "network"
        case .ruleOverview: return "list.number"
        case .routeRules: return "list.bullet.rectangle"
        case .dnsRules: return "server.rack"
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

    private var sourceTabs: [SidebarTab] { [.builtinRules, .regionGroups, .subscriptions] }
    private var ruleTabs: [SidebarTab] { [.routeRules, .dnsRules, .ruleSets, .ruleTest] }
    private var systemTabs: [SidebarTab] { [.settings] }

    @State private var isApplying = false

    var body: some View {
        VStack(spacing: 0) {
            // Pending reload banner
            if appState.pendingReload && appState.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("配置已更新，点击应用后生效（约 1-2 秒短暂断网）")
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
                Label("概览", systemImage: "square.grid.2x2").tag(SidebarTab.overview)
                Label("策略组", systemImage: "network").tag(SidebarTab.proxies)
                Label("规则总览", systemImage: "list.number").tag(SidebarTab.ruleOverview)

                Section("分流") {
                    ForEach(sourceTabs, id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }

                Section("规则") {
                    ForEach(ruleTabs, id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }

                Section {
                    ForEach(systemTabs, id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                    Label("监控", systemImage: "waveform.badge.magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { openWindow(id: "monitor") }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch selectedTab {
            case .overview:
                OverviewView()
            case .proxies:
                ProxiesView()
            case .ruleOverview:
                RuleOverviewView()
            case .routeRules:
                RouteRulesView()
            case .dnsRules:
                DNSRulesView()
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
        .frame(minWidth: 900, minHeight: 550)

        } // end VStack
        .onReceive(NotificationCenter.default.publisher(for: .openMonitorWindow)) { _ in
            openWindow(id: "monitor")
        }
        .onReceive(NotificationCenter.default.publisher(for: .subscriptionLogStart)) { _ in
            openWindow(id: "update-log")
        }
    }
}

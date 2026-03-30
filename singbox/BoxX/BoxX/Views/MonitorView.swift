import SwiftUI

enum MonitorTab: String, CaseIterable {
    case connections = "请求"
    case logs = "日志"

    var icon: String {
        switch self {
        case .connections: return "arrow.left.arrow.right"
        case .logs: return "doc.text"
        }
    }
}

struct MonitorView: View {
    @State private var selectedTab: MonitorTab = .connections

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(MonitorTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 120, ideal: 140, max: 180)
        } detail: {
            switch selectedTab {
            case .connections:
                ConnectionsView()
            case .logs:
                LogsView()
            }
        }
        .frame(minWidth: 700, minHeight: 400)
    }
}

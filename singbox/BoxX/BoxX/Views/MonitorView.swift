import SwiftUI
import AppKit

enum MonitorTab: Hashable {
    case connections
    case logs
}

enum MonitorGroupTab: String, CaseIterable {
    case app = "App"
    case host = "主机"
}

/// Sidebar selection: either a tab or a group filter
enum MonitorSidebarSelection: Hashable {
    case tab(MonitorTab)
    case group(String)
}

struct MonitorView: View {
    @State private var selection: MonitorSidebarSelection = .tab(.connections)
    @State private var groupTab: MonitorGroupTab = .app
    @State private var connectionSummary: [Connection] = []

    private var currentTab: MonitorTab {
        switch selection {
        case .tab(let t): return t
        case .group: return .connections
        }
    }

    private var groupFilter: String? {
        if case .group(let name) = selection { return name }
        return nil
    }

    private var appGroups: [(name: String, count: Int, icon: NSImage?)] {
        Dictionary(grouping: connectionSummary.filter { $0.processName != "\u{2013}" }, by: \.processName)
            .map { (name: $0.key, count: $0.value.count, icon: appIcon(for: $0.value.first?.metadata.processPath ?? "")) }
            .sorted { $0.count > $1.count }
    }

    private var hostGroups: [(name: String, count: Int)] {
        Dictionary(grouping: connectionSummary.filter { !$0.host.isEmpty }, by: \.host)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private func appIcon(for processPath: String) -> NSImage? {
        guard !processPath.isEmpty,
              let range = processPath.range(of: ".app") else { return nil }
        let appPath = String(processPath[...range.upperBound].dropLast())
        return NSWorkspace.shared.icon(forFile: appPath)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Label("请求", systemImage: "arrow.left.arrow.right")
                        .tag(MonitorSidebarSelection.tab(.connections))
                    Label("日志", systemImage: "doc.text")
                        .tag(MonitorSidebarSelection.tab(.logs))
                }
                .listStyle(.sidebar)
                .frame(height: 76)

                if currentTab == .connections {
                    Divider()

                    Picker("", selection: $groupTab) {
                        ForEach(MonitorGroupTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    List(selection: $selection) {
                        switch groupTab {
                        case .app:
                            ForEach(appGroups, id: \.name) { item in
                                groupRow(name: item.name, count: item.count, icon: item.icon)
                                    .tag(MonitorSidebarSelection.group(item.name))
                            }
                        case .host:
                            ForEach(hostGroups, id: \.name) { item in
                                groupRow(name: item.name, count: item.count)
                                    .tag(MonitorSidebarSelection.group(item.name))
                            }
                        }
                    }
                    .listStyle(.sidebar)
                } else {
                    Spacer()
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 240)
        } detail: {
            switch currentTab {
            case .connections:
                ConnectionsView(groupFilter: groupFilter, onConnectionsUpdate: { conns in
                    connectionSummary = conns
                })
            case .logs:
                LogsView()
            }
        }
        .frame(minWidth: 700, minHeight: 400)
    }

    @ViewBuilder
    private func groupRow(name: String, count: Int, icon: NSImage? = nil) -> some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: groupTab == .app ? "app.fill" : "globe")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.gray.opacity(0.15))
                .clipShape(Capsule())
        }
    }
}

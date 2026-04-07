import SwiftUI
import ShadowProxyCore

struct MenuBarPopover: View {
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: status + toggle
            HStack {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text("ShadowProxy")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.isRunning },
                    set: { newValue in
                        if newValue { viewModel.start() } else { viewModel.stop() }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Mode bar
            HStack(spacing: 6) {
                modeButton(title: "系统代理", active: true)
                modeButton(title: "TUN", active: false).opacity(0.4)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Current node
            if let selected = viewModel.selectedNodes["Proxy"] {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前节点")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(selected)
                            .font(.system(size: 13))
                    }
                    Spacer()
                    if let speed = viewModel.nodeSpeeds[selected] {
                        Text("\(speed)ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(speed < 100 ? .green : speed < 300 ? .yellow : .red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }

            // Routing summary
            ScrollView {
                VStack(spacing: 0) {
                    let serviceGroups = viewModel.proxyGroups.filter { $0.name != "Proxy" }
                    ForEach(serviceGroups.prefix(5), id: \.name) { group in
                        HStack {
                            Text(group.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.selectedNodes[group.name] ?? "-")
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    if serviceGroups.count > 5 {
                        Text("更多...")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 150)

            Divider()

            // Bottom bar
            HStack {
                Button("📊 仪表盘") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                Spacer()
                Button("📋 请求") {
                    openWindow(id: "request-viewer")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                Spacer()
                Button("🔄 重载") { viewModel.reload() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                Spacer()
                Button("退出") {
                    viewModel.stop()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
    }

    private func modeButton(title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(active ? Color.accentColor : Color.gray.opacity(0.2))
            .foregroundStyle(active ? .white : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

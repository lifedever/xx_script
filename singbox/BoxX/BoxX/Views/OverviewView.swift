import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var appState
    @State private var snapshot: ConnectionSnapshot?
    @State private var clashConfig: ClashConfig?
    @State private var isOperating = false
    @State private var statsTimer: Timer?
    @State private var downloadSpeed: Int64 = 0
    @State private var uploadSpeed: Int64 = 0

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - Status + Actions
                HStack(spacing: 12) {
                    // Status card (large)
                    dashboardCard {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(appState.isRunning ? Color.green : Color.red.opacity(0.5))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appState.isRunning ? "运行中" : "已停止")
                                    .font(.headline)
                                Text("sing-box")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Action button: context-aware single button
                            if isOperating {
                                ProgressView().controlSize(.small)
                            } else if appState.isRunning {
                                HStack(spacing: 8) {
                                    Button("重启") { Task { await doRestart() } }
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                    Button("停止") { Task { await doStop() } }
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                        .tint(.red)
                                }
                            } else {
                                Button("启动") { Task { await doStart() } }
                                    .controlSize(.regular)
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                            }
                        }
                    }

                    // Proxy mode
                    dashboardCard {
                        VStack(spacing: 6) {
                            Text("代理模式")
                                .font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { clashConfig?.mode ?? "rule" },
                                set: { newMode in
                                    Task {
                                        try? await appState.api.setMode(newMode)
                                        clashConfig = try? await appState.api.getConfig()
                                    }
                                }
                            )) {
                                Text("规则").tag("rule")
                                Text("全局").tag("global")
                                Text("直连").tag("direct")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                }

                // MARK: - Speed row
                HStack(spacing: 12) {
                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2).foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("下载").font(.caption).foregroundStyle(.secondary)
                                Text(speedString(downloadSpeed))
                                    .font(.title3.monospacedDigit().bold())
                            }
                            Spacer()
                            Text(byteFormatter.string(fromByteCount: snapshot?.downloadTotal ?? 0))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("上传").font(.caption).foregroundStyle(.secondary)
                                Text(speedString(uploadSpeed))
                                    .font(.title3.monospacedDigit().bold())
                            }
                            Spacer()
                            Text(byteFormatter.string(fromByteCount: snapshot?.uploadTotal ?? 0))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - Stats row (connections + memory)
                HStack(spacing: 12) {
                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("活跃连接").font(.caption).foregroundStyle(.secondary)
                                Text("\(snapshot?.connections?.count ?? 0)")
                                    .font(.title3.monospacedDigit().bold())
                            }
                            Spacer()
                        }
                    }

                    if let mem = snapshot?.memory {
                        dashboardCard {
                            HStack(spacing: 10) {
                                Image(systemName: "memorychip")
                                    .font(.title2).foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("内存").font(.caption).foregroundStyle(.secondary)
                                    Text(byteFormatter.string(fromByteCount: mem))
                                        .font(.title3.monospacedDigit().bold())
                                }
                                Spacer()
                            }
                        }
                    }
                }

                // MARK: - Proxy info
                dashboardCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("代理信息")
                            .font(.subheadline.bold())

                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                Text("HTTP/SOCKS 代理")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("127.0.0.1:7890")
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                            }
                            GridRow {
                                Text("Clash API")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(appState.configEngine.config.experimental?.clashApi?.externalController ?? "127.0.0.1:9091")
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                            }
                            GridRow {
                                Text("sing-box 路径")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("/opt/homebrew/bin/sing-box")
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                            }
                            GridRow {
                                Text("配置目录")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text(appState.configEngine.baseDir.path)
                                        .font(.body.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Button {
                                        NSWorkspace.shared.open(appState.configEngine.baseDir)
                                    } label: {
                                        Image(systemName: "folder")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.blue)
                                }
                            }
                            GridRow {
                                Text("环境变量")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text("export https_proxy=http://127.0.0.1:7890")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Button("复制") {
                                        let env = """
                                        export https_proxy=http://127.0.0.1:7890
                                        export http_proxy=http://127.0.0.1:7890
                                        export all_proxy=socks5://127.0.0.1:7890
                                        """
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(env, forType: .string)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .task { await refresh() }
        .onChange(of: appState.isRunning) { _, running in
            if running { startStatsPolling() } else { stopStatsPolling(); resetStats() }
        }
        .onDisappear { stopStatsPolling() }
    }

    // MARK: - Card wrapper

    @ViewBuilder
    private func dashboardCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func speedString(_ bytesPerSecond: Int64) -> String {
        byteFormatter.string(fromByteCount: bytesPerSecond) + "/s"
    }

    // MARK: - Stats polling

    private func startStatsPolling() {
        stopStatsPolling()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in await pollStats() }
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats() async {
        guard appState.isRunning else { return }
        let newSnapshot = try? await appState.api.getConnections()
        if let prev = snapshot, let curr = newSnapshot {
            downloadSpeed = max(0, (curr.downloadTotal - prev.downloadTotal) / 2)
            uploadSpeed = max(0, (curr.uploadTotal - prev.uploadTotal) / 2)
        }
        snapshot = newSnapshot
    }

    private func resetStats() {
        snapshot = nil
        clashConfig = nil
        downloadSpeed = 0
        uploadSpeed = 0
    }

    // MARK: - Actions

    private func doStart() async {
        isOperating = true; defer { isOperating = false }
        do {
            try appState.configEngine.deployRuntime()
            let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
            try appState.singBoxProcess.start(configPath: runtimePath)
        } catch {
            appState.showAlert(error.localizedDescription)
        }
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func doStop() async {
        isOperating = true; defer { isOperating = false }
        appState.singBoxProcess.stop()
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func doRestart() async {
        isOperating = true; defer { isOperating = false }
        do {
            try appState.configEngine.deployRuntime()
            let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
            try appState.singBoxProcess.restart(configPath: runtimePath)
        } catch {
            appState.showAlert(error.localizedDescription)
        }
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func refresh() async {
        guard appState.isRunning else { resetStats(); return }
        snapshot = try? await appState.api.getConnections()
        clashConfig = try? await appState.api.getConfig()
        startStatsPolling()
    }
}

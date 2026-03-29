import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var appState
    @State private var snapshot: ConnectionSnapshot?
    @State private var clashConfig: ClashConfig?
    @State private var isOperating = false
    @State private var statsTimer: Timer?
    @State private var previousSnapshot: ConnectionSnapshot?
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
                // MARK: - Top row: Status / Connections / Proxy Mode
                HStack(spacing: 12) {
                    // Status card
                    dashboardCard {
                        VStack(spacing: 6) {
                            Text(String(localized: "overview.status"))
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(appState.isRunning ? Color.green : Color.red.opacity(0.6))
                                    .frame(width: 10, height: 10)
                                Text(appState.isRunning
                                     ? String(localized: "overview.running")
                                     : String(localized: "overview.stopped"))
                                    .font(.headline)
                            }
                        }
                    }

                    // Connections card
                    dashboardCard {
                        VStack(spacing: 6) {
                            Text(String(localized: "overview.connections"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(snapshot?.connections?.count ?? 0)")
                                .font(.title2.monospacedDigit().bold())
                                .foregroundStyle(.blue)
                        }
                    }

                    // Proxy mode card
                    dashboardCard {
                        VStack(spacing: 6) {
                            Text(String(localized: "overview.proxy_mode"))
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
                                Text(String(localized: "menu.mode.rule")).tag("rule")
                                Text(String(localized: "menu.mode.global")).tag("global")
                                Text(String(localized: "menu.mode.direct")).tag("direct")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                }

                // MARK: - Speed row: Download / Upload
                HStack(spacing: 12) {
                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2).foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "overview.download"))
                                    .font(.caption).foregroundStyle(.secondary)
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
                                Text(String(localized: "overview.upload"))
                                    .font(.caption).foregroundStyle(.secondary)
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

                // MARK: - Memory card
                if let mem = snapshot?.memory {
                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "memorychip")
                                .font(.title2).foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "overview.memory"))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(byteFormatter.string(fromByteCount: mem))
                                    .font(.title3.monospacedDigit().bold())
                            }
                            Spacer()
                        }
                    }
                }

                // MARK: - Action buttons
                HStack(spacing: 12) {
                    if isOperating {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Button { Task { await doStart() } } label: {
                            Label(String(localized: "overview.start"), systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(appState.isRunning)

                        Button { Task { await doStop() } } label: {
                            Label(String(localized: "overview.stop"), systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                        .disabled(!appState.isRunning)

                        Button { Task { await doRestart() } } label: {
                            Label(String(localized: "overview.restart"), systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                        .disabled(!appState.isRunning)
                    }
                }
                .padding(.top, 4)
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

    // MARK: - Speed formatting

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
        let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
        let result = await appState.xpcClient.start(configPath: runtimePath)
        if !result.success, let err = result.error {
            appState.showAlert(err)
        }
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func doStop() async {
        isOperating = true; defer { isOperating = false }
        let result = await appState.xpcClient.stop()
        if !result.success, let err = result.error {
            appState.showAlert(err)
        }
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func doRestart() async {
        isOperating = true; defer { isOperating = false }
        _ = await appState.xpcClient.stop()
        try? await Task.sleep(for: .seconds(1))
        let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
        let result = await appState.xpcClient.start(configPath: runtimePath)
        if !result.success, let err = result.error {
            appState.showAlert(err)
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

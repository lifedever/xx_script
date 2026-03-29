import SwiftUI

struct OverviewView: View {
    let api: ClashAPI
    let singBoxManager: SingBoxManager
    let configGenerator: ConfigGenerator

    @Environment(AppState.self) private var appState
    @State private var snapshot: ConnectionSnapshot?
    @State private var clashConfig: ClashConfig?
    @State private var proxyGroupCount: Int = 0
    @State private var ruleCount: Int = 0
    @State private var isLoading = false
    @State private var isOperating = false

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Status + Controls Card
                GroupBox {
                    HStack(spacing: 16) {
                        // Status indicator
                        Image(systemName: singBoxManager.isRunning ? "checkmark.circle.fill" : "xmark.circle")
                            .font(.system(size: 36))
                            .foregroundStyle(singBoxManager.isRunning ? Color.green : Color.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(singBoxManager.isRunning
                                 ? String(localized: "overview.running")
                                 : String(localized: "overview.stopped"))
                                .font(.title3.bold())

                            if singBoxManager.isRunning {
                                if singBoxManager.isExternalProcess {
                                    Text(String(localized: "overview.external_process"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if singBoxManager.pid != 0 {
                                    Text(String(format: String(localized: "overview.pid"), singBoxManager.pid))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Spacer()

                        // Control buttons
                        HStack(spacing: 8) {
                            if isOperating {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else if singBoxManager.isRunning {
                                Button {
                                    Task { await doStop() }
                                } label: {
                                    Label(String(localized: "overview.stop"), systemImage: "stop.fill")
                                }
                                .controlSize(.large)

                                Button {
                                    Task { await doRestart() }
                                } label: {
                                    Label(String(localized: "overview.restart"), systemImage: "arrow.clockwise")
                                }
                                .controlSize(.large)
                            } else {
                                if appState.isHelperInstalled {
                                    Button {
                                        Task { await doStart() }
                                    } label: {
                                        Label(String(localized: "overview.start"), systemImage: "play.fill")
                                    }
                                    .controlSize(.large)
                                    .tint(.green)
                                } else {
                                    Text(String(localized: "overview.need_helper"))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }

                            Button {
                                Task { await doUpdateSubs() }
                            } label: {
                                Label(String(localized: "overview.update_subs"), systemImage: "arrow.down.circle")
                            }
                            .controlSize(.large)
                        }
                    }
                    .padding(8)
                } label: {
                    Label(String(localized: "overview.status"), systemImage: "server.rack")
                }

                // Stats Grid
                if let snap = snapshot {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatCard(
                            title: String(localized: "overview.connections"),
                            value: "\(snap.connections?.count ?? 0)",
                            icon: "link",
                            color: .blue
                        )
                        StatCard(
                            title: String(localized: "overview.download"),
                            value: byteFormatter.string(fromByteCount: snap.downloadTotal),
                            icon: "arrow.down.circle",
                            color: .green
                        )
                        StatCard(
                            title: String(localized: "overview.upload"),
                            value: byteFormatter.string(fromByteCount: snap.uploadTotal),
                            icon: "arrow.up.circle",
                            color: .orange
                        )
                        StatCard(
                            title: String(localized: "overview.memory"),
                            value: snap.memory.map { byteFormatter.string(fromByteCount: $0) } ?? "–",
                            icon: "memorychip",
                            color: .purple
                        )
                    }
                } else if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 30)
                }

                // System Info Card
                GroupBox {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text(String(localized: "overview.proxy_mode"))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                            Picker("", selection: Binding(
                                get: { clashConfig?.mode ?? "rule" },
                                set: { newMode in
                                    Task {
                                        try? await api.setMode(newMode)
                                        clashConfig = try? await api.getConfig()
                                    }
                                }
                            )) {
                                Text(String(localized: "menu.mode.rule")).tag("rule")
                                Text(String(localized: "menu.mode.global")).tag("global")
                                Text(String(localized: "menu.mode.direct")).tag("direct")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .gridColumnAlignment(.leading)
                        }
                        Divider()
                        systemInfoRow(
                            label: String(localized: "overview.http_proxy"),
                            value: "127.0.0.1:7890"
                        )
                        Divider()
                        systemInfoRow(
                            label: String(localized: "overview.api_address"),
                            value: "127.0.0.1:9091"
                        )
                        Divider()
                        systemInfoRow(
                            label: String(localized: "overview.proxy_groups"),
                            value: "\(proxyGroupCount)"
                        )
                        Divider()
                        systemInfoRow(
                            label: String(localized: "overview.rule_count"),
                            value: "\(ruleCount)"
                        )
                        Divider()
                        systemInfoRow(
                            label: String(localized: "overview.config_path"),
                            value: configGenerator.configPath
                        )
                    }
                    .padding(4)
                } label: {
                    Label(String(localized: "overview.system_info"), systemImage: "info.circle")
                }
            }
            .padding()
        }
        .task {
            await refresh()
        }
    }

    @ViewBuilder
    private func systemInfoRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }

    private func modeDisplayName(_ mode: String?) -> String {
        switch mode?.lowercased() {
        case "rule":   return String(localized: "overview.mode.rule")
        case "global": return String(localized: "overview.mode.global")
        case "direct": return String(localized: "overview.mode.direct")
        default:       return mode ?? "–"
        }
    }

    private func doStart() async {
        isOperating = true
        defer { isOperating = false }
        do {
            try await singBoxManager.start(configPath: configGenerator.configPath)
        } catch {
            appState.showAlert(error.localizedDescription)
        }
        await refresh()
    }

    private func doStop() async {
        isOperating = true
        defer { isOperating = false }
        do {
            try await singBoxManager.stopAny()
        } catch {
            appState.showAlert(error.localizedDescription)
        }
        await refresh()
    }

    private func doRestart() async {
        isOperating = true
        defer { isOperating = false }
        do {
            try await singBoxManager.restart(configPath: configGenerator.configPath)
        } catch {
            appState.showAlert(error.localizedDescription)
        }
        await refresh()
    }

    private func doUpdateSubs() async {
        isOperating = true
        defer { isOperating = false }
        for await _ in configGenerator.generate() {}
        if singBoxManager.isRunning {
            do {
                try await singBoxManager.restart(configPath: configGenerator.configPath)
            } catch {
                appState.showAlert(error.localizedDescription)
            }
        }
        await refresh()
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await singBoxManager.refreshStatus()
        appState.isRunning = singBoxManager.isRunning
        appState.pid = singBoxManager.pid
        guard singBoxManager.isRunning else {
            snapshot = nil
            clashConfig = nil
            proxyGroupCount = 0
            ruleCount = 0
            return
        }
        async let snapshotResult = api.getConnections()
        async let configResult = api.getConfig()
        async let proxiesResult = api.getProxies()
        async let rulesResult = api.getRules()
        snapshot = try? await snapshotResult
        clashConfig = try? await configResult
        proxyGroupCount = (try? await proxiesResult)?.count ?? 0
        ruleCount = (try? await rulesResult)?.count ?? 0
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(value)
                    .font(.title3.monospacedDigit().bold())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

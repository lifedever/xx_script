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
                        Image(systemName: singBoxManager.isRunning ? "checkmark.circle.fill" : "xmark.circle")
                            .font(.system(size: 36))
                            .foregroundStyle(singBoxManager.isRunning ? Color.green : Color.secondary)

                        Text(singBoxManager.isRunning
                             ? String(localized: "overview.running")
                             : String(localized: "overview.stopped"))
                            .font(.title3.bold())

                        Spacer()

                        HStack(spacing: 8) {
                            if isOperating {
                                ProgressView().scaleEffect(0.8)
                            } else if singBoxManager.isRunning {
                                Button { Task { await doStop() } } label: {
                                    Label(String(localized: "overview.stop"), systemImage: "stop.fill")
                                }.controlSize(.large)

                                Button { Task { await doRestart() } } label: {
                                    Label(String(localized: "overview.restart"), systemImage: "arrow.clockwise")
                                }.controlSize(.large)
                            } else {
                                Button { Task { await doStart() } } label: {
                                    Label(String(localized: "overview.start"), systemImage: "play.fill")
                                }.controlSize(.large).tint(.green)
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label(String(localized: "overview.status"), systemImage: "server.rack")
                }

                // Stats Grid
                if let snap = snapshot {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatCard(title: String(localized: "overview.connections"), value: "\(snap.connections?.count ?? 0)", icon: "link", color: .blue)
                        StatCard(title: String(localized: "overview.download"), value: byteFormatter.string(fromByteCount: snap.downloadTotal), icon: "arrow.down.circle", color: .green)
                        StatCard(title: String(localized: "overview.upload"), value: byteFormatter.string(fromByteCount: snap.uploadTotal), icon: "arrow.up.circle", color: .orange)
                        StatCard(title: String(localized: "overview.memory"), value: snap.memory.map { byteFormatter.string(fromByteCount: $0) } ?? "–", icon: "memorychip", color: .purple)
                    }
                } else if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 30)
                }

                // System Info
                GroupBox {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text(String(localized: "overview.proxy_mode")).foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { clashConfig?.mode ?? "rule" },
                                set: { newMode in Task { try? await api.setMode(newMode); clashConfig = try? await api.getConfig() } }
                            )) {
                                Text(String(localized: "menu.mode.rule")).tag("rule")
                                Text(String(localized: "menu.mode.global")).tag("global")
                                Text(String(localized: "menu.mode.direct")).tag("direct")
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                        Divider()
                        infoRow(String(localized: "overview.http_proxy"), "127.0.0.1:7890")
                        Divider()
                        infoRow(String(localized: "overview.api_address"), "127.0.0.1:9091")
                        Divider()
                        infoRow(String(localized: "overview.proxy_groups"), "\(proxyGroupCount)")
                        Divider()
                        infoRow(String(localized: "overview.rule_count"), "\(ruleCount)")
                        Divider()
                        infoRow(String(localized: "overview.config_path"), configGenerator.configPath)
                    }
                    .padding(4)
                } label: {
                    Label(String(localized: "overview.system_info"), systemImage: "info.circle")
                }
            }
            .padding()
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func doStart() async {
        isOperating = true; defer { isOperating = false }
        do { try await singBoxManager.start(configPath: configGenerator.configPath) }
        catch { appState.showAlert(error.localizedDescription) }
        await refresh()
    }

    private func doStop() async {
        isOperating = true; defer { isOperating = false }
        do { try await singBoxManager.stop() }
        catch { appState.showAlert(error.localizedDescription) }
        await refresh()
    }

    private func doRestart() async {
        isOperating = true; defer { isOperating = false }
        do { try await singBoxManager.restart(configPath: configGenerator.configPath) }
        catch { appState.showAlert(error.localizedDescription) }
        await refresh()
    }

    private func refresh() async {
        isLoading = true; defer { isLoading = false }
        await singBoxManager.refreshStatus()
        appState.isRunning = singBoxManager.isRunning
        guard singBoxManager.isRunning else { snapshot = nil; clashConfig = nil; proxyGroupCount = 0; ruleCount = 0; return }
        async let s = api.getConnections()
        async let c = api.getConfig()
        async let p = api.getProxies()
        async let r = api.getRules()
        snapshot = try? await s; clashConfig = try? await c
        proxyGroupCount = (try? await p)?.count ?? 0; ruleCount = (try? await r)?.count ?? 0
    }
}

struct StatCard: View {
    let title: String; let value: String; let icon: String; let color: Color
    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                Text(value).font(.title3.monospacedDigit().bold())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
    }
}

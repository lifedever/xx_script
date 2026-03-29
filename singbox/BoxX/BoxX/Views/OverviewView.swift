import SwiftUI

struct OverviewView: View {
    let api: ClashAPI
    let singBoxManager: SingBoxManager
    let configGenerator: ConfigGenerator

    @Environment(AppState.self) private var appState
    @State private var snapshot: ConnectionSnapshot?
    @State private var isLoading = false

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
                            if singBoxManager.isRunning {
                                Button {
                                    Task {
                                        try? await singBoxManager.stopAny()
                                        await singBoxManager.refreshStatus()
                                        appState.isRunning = singBoxManager.isRunning
                                        appState.pid = singBoxManager.pid
                                    }
                                } label: {
                                    Label(String(localized: "overview.stop"), systemImage: "stop.fill")
                                }
                                .controlSize(.large)

                                Button {
                                    Task {
                                        try? await singBoxManager.stopAny()
                                        try? await Task.sleep(for: .seconds(1))
                                        try? await singBoxManager.start(configPath: configGenerator.configPath)
                                        await singBoxManager.refreshStatus()
                                        appState.isRunning = singBoxManager.isRunning
                                        appState.pid = singBoxManager.pid
                                    }
                                } label: {
                                    Label(String(localized: "overview.restart"), systemImage: "arrow.clockwise")
                                }
                                .controlSize(.large)
                            } else {
                                if appState.isHelperInstalled {
                                    Button {
                                        Task {
                                            try? await singBoxManager.start(configPath: configGenerator.configPath)
                                            await singBoxManager.refreshStatus()
                                            appState.isRunning = singBoxManager.isRunning
                                            appState.pid = singBoxManager.pid
                                        }
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
                                Task {
                                    for await _ in configGenerator.generate() {}
                                    if singBoxManager.isRunning {
                                        try? await singBoxManager.stopAny()
                                        try? await Task.sleep(for: .seconds(1))
                                        try? await singBoxManager.start(configPath: configGenerator.configPath)
                                    }
                                    await singBoxManager.refreshStatus()
                                    appState.isRunning = singBoxManager.isRunning
                                }
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
            }
            .padding()
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await singBoxManager.refreshStatus()
        appState.isRunning = singBoxManager.isRunning
        appState.pid = singBoxManager.pid
        guard singBoxManager.isRunning else { snapshot = nil; return }
        snapshot = try? await api.getConnections()
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

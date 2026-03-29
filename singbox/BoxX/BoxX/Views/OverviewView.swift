import SwiftUI

struct OverviewView: View {
    let api: ClashAPI
    let singBoxManager: SingBoxManager

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
                // Status Card
                GroupBox {
                    HStack(spacing: 16) {
                        Image(systemName: singBoxManager.isRunning ? "circle.fill" : "circle")
                            .foregroundStyle(singBoxManager.isRunning ? Color.green : Color.secondary)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(singBoxManager.isRunning ? "Running" : "Stopped")
                                .font(.headline)
                            if singBoxManager.isRunning {
                                if singBoxManager.isExternalProcess {
                                    Text("External process (e.g. box start)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if singBoxManager.pid != 0 {
                                    Text("PID: \(singBoxManager.pid)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(4)
                } label: {
                    Label("Status", systemImage: "server.rack")
                }

                // Stats Grid
                if let snap = snapshot {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatCard(
                            title: "Connections",
                            value: "\(snap.connections?.count ?? 0)",
                            icon: "link"
                        )
                        StatCard(
                            title: "Download",
                            value: byteFormatter.string(fromByteCount: snap.downloadTotal),
                            icon: "arrow.down.circle"
                        )
                        StatCard(
                            title: "Upload",
                            value: byteFormatter.string(fromByteCount: snap.uploadTotal),
                            icon: "arrow.up.circle"
                        )
                        StatCard(
                            title: "Memory",
                            value: snap.memory.map { byteFormatter.string(fromByteCount: $0) } ?? "N/A",
                            icon: "memorychip"
                        )
                    }
                } else {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("No data — start sing-box first")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                }
            }
            .padding()
        }
        .task {
            await loadData()
        }
        .refreshable {
            await loadData()
        }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        snapshot = try? await api.getConnections()
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        GroupBox {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.title3.monospacedDigit())
                        .bold()
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(4)
        }
    }
}

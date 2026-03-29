import SwiftUI

struct ConnectionsView: View {
    let api: ClashAPI

    @State private var connections: [Connection] = []
    @State private var downloadTotal: Int64 = 0
    @State private var uploadTotal: Int64 = 0
    @State private var searchText = ""
    @State private var wsTask: Task<Void, Never>?

    private let wsClient = ClashWebSocket()
    private let maxRows = 500

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    var filteredConnections: [Connection] {
        let prefix = Array(connections.prefix(maxRows))
        if searchText.isEmpty { return prefix }
        return prefix.filter {
            $0.host.localizedCaseInsensitiveContains(searchText)
            || $0.rule.localizedCaseInsensitiveContains(searchText)
            || $0.outbound.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search connections…", text: $searchText)
                    .textFieldStyle(.plain)
                Spacer()
                Text("\(filteredConnections.count) connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("↓ \(byteFormatter.string(fromByteCount: downloadTotal))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
                Text("↑ \(byteFormatter.string(fromByteCount: uploadTotal))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.blue)
                Button("Close All") {
                    Task { try? await api.closeAllConnections() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            Table(filteredConnections) {
                TableColumn("Host", value: \.host)
                    .width(min: 150, ideal: 200)
                TableColumn("Rule", value: \.rule)
                    .width(min: 80, ideal: 120)
                TableColumn("Outbound", value: \.outbound)
                    .width(min: 80, ideal: 120)
                TableColumn("Chain", value: \.chain)
                    .width(min: 100, ideal: 150)
                TableColumn("Download") { conn in
                    Text(byteFormatter.string(fromByteCount: conn.download))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 60, ideal: 90)
                TableColumn("Upload") { conn in
                    Text(byteFormatter.string(fromByteCount: conn.upload))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 60, ideal: 90)
            }
        }
        .task {
            wsTask = Task {
                for await snapshot in wsClient.connectConnections() {
                    connections = snapshot.connections ?? []
                    downloadTotal = snapshot.downloadTotal
                    uploadTotal = snapshot.uploadTotal
                }
            }
        }
        .onDisappear {
            wsTask?.cancel()
            wsClient.disconnect()
        }
    }
}

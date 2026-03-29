import SwiftUI

struct ConnectionsView: View {
    let api: ClashAPI

    @State private var connections: [Connection] = []
    @State private var downloadTotal: Int64 = 0
    @State private var uploadTotal: Int64 = 0
    @State private var searchText = ""
    @State private var wsTask: Task<Void, Never>?
    @State private var sortOrder = [KeyPathComparator(\Connection.start, order: .reverse)]
    @State private var selectedID: Connection.ID?
    @State private var showAddRule = false
    @State private var addRuleConnection: Connection?

    private let wsClient = ClashWebSocket()

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    var filteredConnections: [Connection] {
        let sorted = connections.sorted(using: sortOrder)
        let capped = Array(sorted.prefix(500))
        if searchText.isEmpty { return capped }
        return capped.filter {
            $0.host.localizedCaseInsensitiveContains(searchText) ||
            $0.rule.localizedCaseInsensitiveContains(searchText) ||
            $0.outbound.localizedCaseInsensitiveContains(searchText) ||
            $0.chain.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selectedConnection: Connection? {
        guard let id = selectedID else { return nil }
        return connections.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "connections.search"), text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Spacer()

                Text(String(format: String(localized: "connections.count"), filteredConnections.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("↓ \(byteFormatter.string(fromByteCount: downloadTotal))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
                Text("↑ \(byteFormatter.string(fromByteCount: uploadTotal))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.blue)

                Button(String(localized: "connections.close_all")) {
                    Task { try? await api.closeAllConnections() }
                }
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Table + Detail split
            VSplitView {
                // Table
                Table(filteredConnections, selection: $selectedID, sortOrder: $sortOrder) {
                    TableColumn(String(localized: "connections.time"), value: \.start) { conn in
                        Text(conn.startTimeString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 70)

                    TableColumn(String(localized: "connections.host"), value: \.host) { conn in
                        Text(conn.host)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .width(min: 150, ideal: 220)

                    TableColumn(String(localized: "connections.network")) { conn in
                        Text(conn.network)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(conn.network == "UDP" ? Color.orange.opacity(0.15) : Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .width(min: 40, ideal: 50)

                    TableColumn(String(localized: "connections.rule"), value: \.rule) { conn in
                        Text(conn.rule)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 160)

                    TableColumn(String(localized: "connections.outbound"), value: \.outbound)
                        .width(min: 80, ideal: 100)

                    TableColumn(String(localized: "connections.chain")) { conn in
                        Text(conn.chain)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("↓") { conn in
                        Text(byteFormatter.string(fromByteCount: conn.download))
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 50, ideal: 70)

                    TableColumn("↑") { conn in
                        Text(byteFormatter.string(fromByteCount: conn.upload))
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 50, ideal: 70)
                }
                .contextMenu(forSelectionType: Connection.ID.self) { ids in
                    if let id = ids.first, let conn = connections.first(where: { $0.id == id }) {
                        Button(String(localized: "connections.ctx.copy_host")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(conn.host, forType: .string)
                        }
                        Divider()
                        Button(String(localized: "connections.ctx.add_rule")) {
                            addRuleConnection = conn
                            showAddRule = true
                        }
                        Divider()
                        Button(String(localized: "connections.ctx.close")) {
                            Task { try? await api.closeConnection(id: conn.id) }
                        }
                    }
                } primaryAction: { _ in }

                // Detail panel
                if let conn = selectedConnection {
                    ConnectionDetailPanel(connection: conn, byteFormatter: byteFormatter) {
                        addRuleConnection = conn
                        showAddRule = true
                    } onClose: {
                        Task { try? await api.closeConnection(id: conn.id) }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddRule) {
            if let conn = addRuleConnection {
                AddRuleSheet(
                    host: conn.host,
                    domain: conn.domainForRule,
                    ip: conn.metadata.destinationIP,
                    onDismiss: { showAddRule = false }
                )
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

// MARK: - Detail Panel

struct ConnectionDetailPanel: View {
    let connection: Connection
    let byteFormatter: ByteCountFormatter
    let onAddRule: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "connections.detail.title"))
                            .font(.headline)
                        Spacer()
                        Button(String(localized: "connections.ctx.add_rule")) { onAddRule() }
                            .controlSize(.small)
                        Button(String(localized: "connections.ctx.close")) { onClose() }
                            .controlSize(.small)
                            .tint(.red)
                    }

                    LazyVGrid(columns: [GridItem(.fixed(100), alignment: .trailing), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                        DetailRow(label: String(localized: "connections.host"), value: connection.host)
                        DetailRow(label: "IP", value: connection.metadata.destinationIP)
                        DetailRow(label: String(localized: "connections.detail.port"), value: connection.metadata.destinationPort)
                        DetailRow(label: String(localized: "connections.network"), value: connection.network)
                        DetailRow(label: String(localized: "connections.detail.type"), value: connection.metadata.type)
                        DetailRow(label: String(localized: "connections.rule"), value: connection.rule)
                        DetailRow(label: String(localized: "connections.outbound"), value: connection.outbound)
                        DetailRow(label: String(localized: "connections.chain"), value: connection.chain)
                        DetailRow(label: String(localized: "connections.detail.source"), value: "\(connection.metadata.sourceIP):\(connection.metadata.sourcePort)")
                        DetailRow(label: String(localized: "connections.time"), value: connection.startTimeString)
                        DetailRow(label: "↓", value: byteFormatter.string(fromByteCount: connection.download))
                        DetailRow(label: "↑", value: byteFormatter.string(fromByteCount: connection.upload))
                        if !connection.metadata.processPath.isEmpty {
                            DetailRow(label: String(localized: "connections.detail.process"), value: connection.metadata.processPath)
                        }
                    }
                }
                .padding()
            }
            .frame(height: 240)
            .background(.bar)
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(value)
            .font(.caption.monospaced())
            .textSelection(.enabled)
    }
}

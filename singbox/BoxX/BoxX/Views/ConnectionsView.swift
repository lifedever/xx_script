import SwiftUI

struct ConnectionsView: View {
    @Environment(AppState.self) private var appState

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
                    Task { try? await appState.api.closeAllConnections() }
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
                            Task { try? await appState.api.closeConnection(id: conn.id) }
                        }
                    }
                } primaryAction: { _ in }

                // Detail panel
                if let conn = selectedConnection {
                    ConnectionDetailPanel(
                        connection: conn,
                        byteFormatter: byteFormatter,
                        onAddRule: {
                            addRuleConnection = conn
                            showAddRule = true
                        },
                        onCloseConnection: {
                            Task { try? await appState.api.closeConnection(id: conn.id) }
                        },
                        onDismiss: { selectedID = nil }
                    )
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

// MARK: - Detail Panel (resizable, closable)

struct ConnectionDetailPanel: View {
    let connection: Connection
    let byteFormatter: ByteCountFormatter
    let onAddRule: () -> Void
    let onCloseConnection: () -> Void
    let onDismiss: () -> Void

    @State private var panelHeight: CGFloat = 200
    private let minHeight: CGFloat = 120
    private let maxHeight: CGFloat = 500

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle + header
            VStack(spacing: 0) {
                // Drag bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 36, height: 4)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                HStack {
                    Text(String(localized: "connections.detail.title"))
                        .font(.headline)

                    Text(connection.host)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Button(String(localized: "connections.ctx.add_rule")) { onAddRule() }
                        .controlSize(.small)
                    Button(String(localized: "connections.ctx.close")) { onCloseConnection() }
                        .controlSize(.small)
                        .tint(.red)
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .background(.bar)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newHeight = panelHeight - value.translation.height
                        panelHeight = min(max(newHeight, minHeight), maxHeight)
                    }
            )
            .cursor(.resizeUpDown)

            Divider()

            // Content
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    DetailGridRow(label: String(localized: "connections.host"), value: connection.host)
                    DetailGridRow(label: "IP", value: connection.metadata.destinationIP)
                    DetailGridRow(label: String(localized: "connections.detail.port"), value: connection.metadata.destinationPort)
                    DetailGridRow(label: String(localized: "connections.network"), value: connection.network)
                    DetailGridRow(label: String(localized: "connections.detail.type"), value: connection.metadata.type)
                    Divider()
                    DetailGridRow(label: String(localized: "connections.rule"), value: connection.rule)
                    DetailGridRow(label: String(localized: "connections.outbound"), value: connection.outbound)
                    DetailGridRow(label: String(localized: "connections.chain"), value: connection.chain)
                    Divider()
                    DetailGridRow(label: String(localized: "connections.detail.source"), value: "\(connection.metadata.sourceIP):\(connection.metadata.sourcePort)")
                    DetailGridRow(label: String(localized: "connections.time"), value: connection.startTimeString)
                    DetailGridRow(label: "↓ " + String(localized: "connections.download"), value: byteFormatter.string(fromByteCount: connection.download))
                    DetailGridRow(label: "↑ " + String(localized: "connections.upload"), value: byteFormatter.string(fromByteCount: connection.upload))
                    if !connection.metadata.processPath.isEmpty {
                        DetailGridRow(label: String(localized: "connections.detail.process"), value: connection.metadata.processPath)
                    }
                }
                .padding()
            }
            .frame(height: panelHeight)
            .background(.background.opacity(0.95))
        }
    }
}

struct DetailGridRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}

// Cursor modifier for drag handle
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

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
    @State private var isPaused = false

    private let wsClient = ClashWebSocket()

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    var filteredConnections: [Connection] {
        let sorted = connections.sorted(using: sortOrder)
        let capped = Array(sorted.prefix(2000))
        if searchText.isEmpty { return capped }
        return capped.filter {
            $0.host.localizedCaseInsensitiveContains(searchText) ||
            $0.rule.localizedCaseInsensitiveContains(searchText) ||
            $0.outbound.localizedCaseInsensitiveContains(searchText) ||
            $0.chain.localizedCaseInsensitiveContains(searchText) ||
            $0.metadata.processPath.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selectedConnection: Connection? {
        guard let id = selectedID else { return nil }
        return connections.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar

            Divider()

            // Connection table
            connectionTable

            // Bottom detail panel (slides in when selected)
            if let conn = selectedConnection {
                Divider()
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
                .frame(height: 250)
                .transition(.move(edge: .bottom))
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
            startStreaming()
        }
        .onDisappear {
            wsTask?.cancel()
            wsClient.disconnect()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "connections.search"), text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 260)

            Spacer()

            Text(String(format: String(localized: "connections.count"), filteredConnections.count))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\u{2193} \(byteFormatter.string(fromByteCount: downloadTotal))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)
            Text("\u{2191} \(byteFormatter.string(fromByteCount: uploadTotal))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.blue)

            // Pause / Resume
            Button {
                isPaused.toggle()
                if isPaused {
                    wsTask?.cancel()
                    wsClient.disconnect()
                } else {
                    startStreaming()
                }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
            }
            .help(isPaused ? String(localized: "connections.resume") : String(localized: "connections.pause"))
            .controlSize(.small)

            // Clear
            Button {
                connections.removeAll()
                selectedID = nil
            } label: {
                Image(systemName: "trash")
            }
            .help(String(localized: "connections.clear"))
            .controlSize(.small)

            // Disconnect All
            Button(String(localized: "connections.close_all")) {
                Task { try? await appState.api.closeAllConnections() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Connection Table

    private var connectionTable: some View {
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
                    .foregroundStyle(conn.network == "UDP" ? Color.orange : Color.blue)
                    .background(conn.network == "UDP" ? Color.orange.opacity(0.12) : Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .width(min: 40, ideal: 50)

            TableColumn(String(localized: "connections.process")) { conn in
                Text(conn.processName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 90)

            TableColumn(String(localized: "connections.rule"), value: \.rule) { conn in
                HStack(spacing: 3) {
                    Text(conn.rule)
                        .font(.caption)
                        .lineLimit(1)
                    if !conn.rulePayload.isEmpty {
                        Text("(\(conn.rulePayload))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 100, ideal: 160)

            TableColumn(String(localized: "connections.outbound"), value: \.outbound) { conn in
                HStack(spacing: 4) {
                    if conn.outbound == "DIRECT" {
                        Text(conn.outbound)
                            .font(.caption.bold())
                    } else {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(conn.outbound)
                            .font(.caption)
                    }
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn(String(localized: "connections.chain")) { conn in
                Text(connectionChainDisplay(conn))
                    .font(.caption)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 150)

            TableColumn("\u{2193}") { conn in
                Text(byteFormatter.string(fromByteCount: conn.download))
                    .font(.caption.monospacedDigit())
            }
            .width(min: 50, ideal: 70)

            TableColumn("\u{2191}") { conn in
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
    }

    // MARK: - Helpers

    private func connectionChainDisplay(_ conn: Connection) -> String {
        let reversed = conn.chains.reversed()
        return reversed.joined(separator: " \u{2192} ")
    }

    private func startStreaming() {
        wsTask = Task {
            for await snapshot in wsClient.connectConnections() {
                if !isPaused {
                    mergeSnapshot(snapshot)
                    downloadTotal = snapshot.downloadTotal
                    uploadTotal = snapshot.uploadTotal
                }
            }
        }
    }

    /// Merge new snapshot into accumulated connections list.
    /// Updates traffic for existing connections, adds new ones at the top,
    /// and keeps closed connections visible.
    private func mergeSnapshot(_ snapshot: ConnectionSnapshot) {
        let activeConnections = snapshot.connections ?? []

        var updatedConnections = connections
        for active in activeConnections {
            if let idx = updatedConnections.firstIndex(where: { $0.id == active.id }) {
                updatedConnections[idx] = active  // Update traffic data
            } else {
                updatedConnections.insert(active, at: 0)  // New connection, add to top
            }
        }

        connections = updatedConnections
    }
}

// MARK: - Detail Panel (bottom panel, horizontal layout)

struct ConnectionDetailPanel: View {
    let connection: Connection
    let byteFormatter: ByteCountFormatter
    let onAddRule: () -> Void
    let onCloseConnection: () -> Void
    let onDismiss: () -> Void

    private var duration: String {
        guard let start = connection.startDate else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 60 { return String(format: "%.0fs", elapsed) }
        if elapsed < 3600 { return String(format: "%.0fm %.0fs", (elapsed / 60).rounded(.down), elapsed.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%.0fh %.0fm", (elapsed / 3600).rounded(.down), (elapsed.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(connection.host)
                    .font(.headline.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 12) {
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Content - horizontal multi-column layout
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    // Left column: Connection info
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(String(localized: "connections.detail.connection_info"))
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            DetailGridRow(label: String(localized: "connections.time"), value: connection.startTimeString)
                            DetailGridRow(label: "IP", value: connection.metadata.destinationIP)
                            DetailGridRow(label: String(localized: "connections.detail.port"), value: connection.metadata.destinationPort)
                            DetailGridRow(label: String(localized: "connections.network"), value: connection.network)
                            DetailGridRow(label: String(localized: "connections.detail.type"), value: connection.metadata.type)
                            DetailGridRow(label: String(localized: "connections.detail.duration"), value: duration)
                        }
                    }
                    .frame(minWidth: 180)

                    Divider()

                    // Middle column: Rule match + outbound chain
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(String(localized: "connections.detail.rule_match"))
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            DetailGridRow(label: String(localized: "connections.rule"), value: connection.rule)
                            if !connection.rulePayload.isEmpty {
                                DetailGridRow(label: String(localized: "connections.detail.rule_payload"), value: connection.rulePayload)
                            }
                        }

                        sectionHeader(String(localized: "connections.detail.outbound_chain"))
                        HStack(spacing: 4) {
                            ForEach(Array(connection.chains.reversed().enumerated()), id: \.offset) { index, node in
                                if index > 0 {
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                chainNodeView(node, isLast: index == connection.chains.count - 1)
                            }
                        }
                    }
                    .frame(minWidth: 180)

                    Divider()

                    // Right column: Traffic + source
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(String(localized: "connections.detail.traffic"))
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            DetailGridRow(label: "\u{2193} " + String(localized: "connections.download"), value: byteFormatter.string(fromByteCount: connection.download))
                            DetailGridRow(label: "\u{2191} " + String(localized: "connections.upload"), value: byteFormatter.string(fromByteCount: connection.upload))
                        }

                        if !connection.metadata.sourceIP.isEmpty {
                            sectionHeader(String(localized: "connections.detail.source"))
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                                DetailGridRow(label: "IP", value: "\(connection.metadata.sourceIP):\(connection.metadata.sourcePort)")
                                if !connection.metadata.processPath.isEmpty {
                                    DetailGridRow(label: String(localized: "connections.detail.process"), value: connection.metadata.processPath)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 180)

                    Spacer()
                }
                .padding()
            }
            .background(.background.opacity(0.95))
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func chainNodeView(_ node: String, isLast: Bool) -> some View {
        HStack(spacing: 4) {
            if node == "DIRECT" {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Text(node)
                .font(.caption.monospaced())
                .fontWeight(node == "DIRECT" ? .bold : .regular)
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

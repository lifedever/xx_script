import SwiftUI

struct ConnectionsView: View {
    let api: ClashAPI

    @State private var connections: [Connection] = []
    @State private var downloadTotal: Int64 = 0
    @State private var uploadTotal: Int64 = 0
    @State private var searchText = ""
    @State private var wsTask: Task<Void, Never>?
    @State private var sortOrder = [KeyPathComparator(\Connection.start, order: .reverse)]

    private let wsClient = ClashWebSocket()
    private let maxRows = 500

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    var filteredConnections: [Connection] {
        let sorted = connections.sorted(using: sortOrder)
        let prefix = Array(sorted.prefix(maxRows))
        if searchText.isEmpty { return prefix }
        return prefix.filter {
            $0.host.localizedCaseInsensitiveContains(searchText) ||
            $0.rule.localizedCaseInsensitiveContains(searchText) ||
            $0.outbound.localizedCaseInsensitiveContains(searchText) ||
            $0.chain.localizedCaseInsensitiveContains(searchText)
        }
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

            Table(filteredConnections, sortOrder: $sortOrder) {
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
                        .help(conn.host)
                }
                .width(min: 150, ideal: 220)

                TableColumn(String(localized: "connections.network")) { conn in
                    Text(conn.network)
                        .font(.caption.monospaced())
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
                        .help(conn.rule)
                }
                .width(min: 100, ideal: 160)

                TableColumn(String(localized: "connections.outbound"), value: \.outbound) { conn in
                    Text(conn.outbound)
                        .font(.caption)
                }
                .width(min: 80, ideal: 110)

                TableColumn(String(localized: "connections.chain")) { conn in
                    Text(conn.chain)
                        .font(.caption)
                        .lineLimit(1)
                        .help(conn.chain)
                }
                .width(min: 100, ideal: 160)

                TableColumn("↓ " + String(localized: "connections.download")) { conn in
                    Text(byteFormatter.string(fromByteCount: conn.download))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 60, ideal: 80)

                TableColumn("↑ " + String(localized: "connections.upload")) { conn in
                    Text(byteFormatter.string(fromByteCount: conn.upload))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 60, ideal: 80)
            }
            .contextMenu(forSelectionType: Connection.ID.self) { ids in
                if let id = ids.first, let conn = connections.first(where: { $0.id == id }) {
                    contextMenuItems(for: conn)
                }
            } primaryAction: { _ in }
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

    @ViewBuilder
    private func contextMenuItems(for conn: Connection) -> some View {
        let host = conn.host
        let domain = conn.domainForRule

        Button(String(localized: "connections.ctx.copy_host")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host, forType: .string)
        }

        Divider()

        if !conn.metadata.host.isEmpty {
            Menu(String(localized: "connections.ctx.add_rule")) {
                Button("DOMAIN-SUFFIX,\(domain) → Proxy") {
                    addRule("DOMAIN-SUFFIX", value: domain, target: "Proxy")
                }
                Button("DOMAIN-SUFFIX,\(domain) → DIRECT") {
                    addRule("DOMAIN-SUFFIX", value: domain, target: "DIRECT")
                }
                Button("DOMAIN,\(host) → Proxy") {
                    addRule("DOMAIN", value: host, target: "Proxy")
                }
                Button("DOMAIN,\(host) → DIRECT") {
                    addRule("DOMAIN", value: host, target: "DIRECT")
                }
            }
        } else {
            Menu(String(localized: "connections.ctx.add_rule")) {
                Button("IP-CIDR,\(host)/32 → Proxy") {
                    addRule("IP-CIDR", value: "\(host)/32", target: "Proxy")
                }
                Button("IP-CIDR,\(host)/32 → DIRECT") {
                    addRule("IP-CIDR", value: "\(host)/32", target: "DIRECT")
                }
            }
        }

        Divider()

        Button(String(localized: "connections.ctx.close")) {
            Task { try? await api.closeConnection(id: conn.id) }
        }
    }

    private func addRule(_ type: String, value: String, target: String) {
        let rule = "\(type),\(value)"
        // Copy to clipboard for now — user can paste into rule files
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rule, forType: .string)

        // Show notification
        let alert = NSAlert()
        alert.messageText = String(localized: "connections.ctx.rule_copied_title")
        alert.informativeText = String(format: String(localized: "connections.ctx.rule_copied_msg"), rule, target)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "error.ok"))
        alert.runModal()
    }
}

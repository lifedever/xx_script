import SwiftUI

struct LogsView: View {
    private static let levelOrder = ["debug", "info", "warning", "error"]

    @State private var ringBuffer = RingBuffer<LogEntry>(capacity: 1000)
    @State private var logEntries: [LogEntry] = []
    @State private var selectedLevel = "info"
    @State private var autoScroll = true
    @State private var wsTask: Task<Void, Never>?

    @State private var wsClient = ClashWebSocket()

    var filteredEntries: [LogEntry] {
        let selfLevel = Self.levelOrder.firstIndex(of: selectedLevel) ?? 0
        return logEntries.filter {
            (Self.levelOrder.firstIndex(of: $0.level) ?? 0) >= selfLevel
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Level filter buttons
                ForEach(Self.levelOrder, id: \.self) { level in
                    Button(level.capitalized) {
                        selectedLevel = level
                        restartWebSocket()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(selectedLevel == level ? levelColor(level) : nil)
                }

                Spacer()

                Toggle(String(localized: "logs.auto_scroll"), isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Button(String(localized: "logs.clear")) {
                    ringBuffer.removeAll()
                    logEntries = []
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                List(filteredEntries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.level.uppercased())
                            .font(.caption.monospaced())
                            .frame(width: 60, alignment: .leading)
                            .foregroundStyle(levelColor(entry.level))
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .id(entry.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                }
                .listStyle(.plain)
                .onChange(of: filteredEntries.count) { _, _ in
                    if autoScroll, let last = filteredEntries.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .task {
            startWebSocket()
        }
        .onDisappear {
            wsTask?.cancel()
            wsClient.disconnect()
        }
    }

    private func startWebSocket() {
        wsTask = Task {
            for await entry in wsClient.connectLogs(level: selectedLevel) {
                ringBuffer.append(entry)
                logEntries = Array(ringBuffer)
            }
        }
    }

    private func restartWebSocket() {
        wsTask?.cancel()
        wsClient.disconnect()
        wsClient = ClashWebSocket()
        ringBuffer.removeAll()
        logEntries = []
        startWebSocket()
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "debug": return .gray
        case "info": return .blue
        case "warning": return .orange
        case "error": return .red
        default: return .primary
        }
    }
}

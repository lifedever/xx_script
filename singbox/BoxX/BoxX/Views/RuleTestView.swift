import SwiftUI

struct RuleTestView: View {
    @Environment(AppState.self) private var appState
    @State private var input = ""
    @State private var isTesting = false
    @State private var results: [RuleTestResultEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            // Title + Input bar (always at top)
            VStack(spacing: 0) {
                HStack {
                    Text("规则测试")
                        .font(.title.bold())
                    Spacer()
                    if !results.isEmpty {
                        Button("清空") { results.removeAll() }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 12)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("输入域名或 IP，如 google.com、8.8.8.8", text: $input)
                        .textFieldStyle(.plain)
                        .onSubmit { test() }

                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("测试") { test() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || !appState.isRunning)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()
            }

            // Results area
            if !appState.isRunning {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("sing-box 未运行")
                        .font(.headline)
                    Text("请先启动 sing-box 后再进行规则测试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if results.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("输入域名或 IP 进行测试")
                        .font(.headline)
                    Text("查看请求匹配的规则和代理出口链路")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(results) { entry in
                    RuleTestResultRow(entry: entry)
                }
                .listStyle(.plain)
            }
        }
    }

    private func test() {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        // Strip protocol prefix if present
        var target = raw
        if let url = URL(string: raw), let host = url.host {
            target = host
        } else if raw.contains("://") {
            target = raw.components(separatedBy: "://").last ?? raw
        }
        // Strip path
        target = target.components(separatedBy: "/").first ?? target
        // Strip port
        if target.contains(":") {
            let parts = target.components(separatedBy: ":")
            if parts.count == 2, Int(parts[1]) != nil {
                target = parts[0]
            }
        }

        // If no TLD, append .com for the actual test request
        let testDomain: String
        if !target.contains(".") && !target.contains(":") {
            testDomain = target + ".com"
        } else {
            testDomain = target
        }

        guard !target.isEmpty else { return }

        isTesting = true

        Task {
            defer { isTesting = false }

            let port = appState.configEngine.mixedPort
            let result = await appState.api.testRule(domain: testDomain, proxyPort: port)

            let entry = RuleTestResultEntry(
                id: UUID(),
                query: target,
                timestamp: Date(),
                result: result
            )
            results.insert(entry, at: 0)
            if results.count > 50 { results = Array(results.prefix(50)) }
        }
    }
}

struct RuleTestResultEntry: Identifiable {
    let id: UUID
    let query: String
    let timestamp: Date
    let result: RuleTestResult?

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }
}

struct RuleTestResultRow: View {
    let entry: RuleTestResultEntry

    var body: some View {
        if let r = entry.result {
            HStack(spacing: 0) {
                Text(entry.timeString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)

                Text(entry.query)
                    .font(.body.monospaced())
                    .fontWeight(.medium)
                    .frame(minWidth: 160, alignment: .leading)

                Spacer().frame(width: 16)

                HStack(spacing: 4) {
                    Image(systemName: "target")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(r.rule)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 120, alignment: .leading)

                Spacer().frame(width: 16)

                // Chain
                HStack(spacing: 4) {
                    let nodes = r.chain.components(separatedBy: " -> ")
                    ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                        if index > 0 {
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(node)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(chainColor(node).opacity(0.12))
                            .foregroundStyle(chainColor(node))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                Spacer()

                if !r.destinationIP.isEmpty {
                    Text(r.destinationIP)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 0) {
                Text(entry.timeString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)

                Text(entry.query)
                    .font(.body.monospaced())
                    .fontWeight(.medium)
                    .frame(minWidth: 160, alignment: .leading)

                Spacer().frame(width: 16)

                Text("未匹配到规则")
                    .font(.caption)
                    .foregroundStyle(.red)

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private func chainColor(_ node: String) -> Color {
        if node == "DIRECT" { return .green }
        if node == "REJECT" { return .red }
        return .blue
    }
}

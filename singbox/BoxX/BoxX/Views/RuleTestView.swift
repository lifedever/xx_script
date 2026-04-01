import SwiftUI

struct RuleTestView: View {
    @Environment(AppState.self) private var appState
    @State private var input = ""
    @State private var isTesting = false
    @State private var results: [RuleTestResultEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            // Title + Input bar
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
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(results) { entry in
                            RuleTestFlowCard(entry: entry)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func test() {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        var target = raw
        if let url = URL(string: raw), let host = url.host {
            target = host
        } else if raw.contains("://") {
            target = raw.components(separatedBy: "://").last ?? raw
        }
        target = target.components(separatedBy: "/").first ?? target
        if target.contains(":") {
            let parts = target.components(separatedBy: ":")
            if parts.count == 2, Int(parts[1]) != nil {
                target = parts[0]
            }
        }

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

// MARK: - Flow Card (Pipeline Style)

struct RuleTestFlowCard: View {
    let entry: RuleTestResultEntry
    private let dotSize: CGFloat = 10
    private let rowH: CGFloat = 48

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let r = entry.result {
                let nodes = buildNodes(r)
                pipelineColumn(count: nodes.count)
                    .frame(width: 40, height: CGFloat(nodes.count) * rowH)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                        nodeRow(node)
                            .frame(height: rowH)
                    }
                }
            } else {
                let nodes: [FlowNode] = [
                    .domain(entry.query, ip: nil),
                    .noMatch
                ]
                pipelineColumn(count: nodes.count)
                    .frame(width: 40, height: CGFloat(nodes.count) * rowH)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                        nodeRow(node)
                            .frame(height: rowH)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack {
                Text(entry.timeString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pipeline

    @ViewBuilder
    private func pipelineColumn(count: Int) -> some View {
        Canvas { context, size in
            let centerX = size.width / 2

            for i in 0..<count {
                let centerY = CGFloat(i) * rowH + rowH / 2

                if i > 0 {
                    let prevCenterY = CGFloat(i - 1) * rowH + rowH / 2
                    // Line
                    var line = Path()
                    line.move(to: CGPoint(x: centerX, y: prevCenterY + dotSize / 2 + 2))
                    line.addLine(to: CGPoint(x: centerX, y: centerY - dotSize / 2 - 8))
                    context.stroke(line, with: .color(.primary.opacity(0.2)), lineWidth: 1.5)

                    // Arrow
                    let arrowY = centerY - dotSize / 2 - 4
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: centerX - 4, y: arrowY - 6))
                    arrow.addLine(to: CGPoint(x: centerX, y: arrowY))
                    arrow.addLine(to: CGPoint(x: centerX + 4, y: arrowY - 6))
                    context.stroke(arrow, with: .color(.primary.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }

                // Dot
                let dotRect = CGRect(x: centerX - dotSize / 2, y: centerY - dotSize / 2, width: dotSize, height: dotSize)
                let color: Color = i == 0 ? .blue : (i == count - 1 ? .green : .orange)
                context.fill(Circle().path(in: dotRect), with: .color(color))
                let innerRect = dotRect.insetBy(dx: 3, dy: 3)
                context.fill(Circle().path(in: innerRect), with: .color(.white))
            }
        }
    }

    // MARK: - Node Types

    private enum FlowNode {
        case domain(String, ip: String?)
        case rule(action: String, condition: String?)
        case proxy(String, isLast: Bool)
        case noMatch
    }

    private func buildNodes(_ r: RuleTestResult) -> [FlowNode] {
        var nodes: [FlowNode] = []
        nodes.append(.domain(entry.query, ip: r.destinationIP.isEmpty ? nil : r.destinationIP))
        nodes.append(.rule(action: formatRuleName(r.rule), condition: formatRuleDetail(r.rule)))
        let chain = r.chain.components(separatedBy: " -> ")
        for (i, node) in chain.enumerated() {
            nodes.append(.proxy(node, isLast: i == chain.count - 1))
        }
        return nodes
    }

    @ViewBuilder
    private func nodeRow(_ node: FlowNode) -> some View {
        switch node {
        case .domain(let name, let ip):
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .textSelection(.enabled)
                if let ip {
                    Text(ip)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .rule(let action, let condition):
            HStack(spacing: 6) {
                Text(action)
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(.orange)
                if let condition {
                    Text(condition)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .proxy(let name, _):
            Text(name)
                .font(.system(.callout, design: .monospaced, weight: .medium))
                .foregroundStyle(chainColor(name))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .noMatch:
            Text("未匹配到规则")
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private func chainColor(_ node: String) -> Color {
        if node == "DIRECT" { return .green }
        if node == "REJECT" { return .red }
        return .blue
    }

    private func formatRuleName(_ rule: String) -> String {
        if let arrowRange = rule.range(of: " => ") {
            return String(rule[arrowRange.upperBound...])
        }
        return rule
    }

    private func formatRuleDetail(_ rule: String) -> String? {
        if let arrowRange = rule.range(of: " => ") {
            let condition = String(rule[..<arrowRange.lowerBound])
            return condition.isEmpty ? nil : condition
        }
        return nil
    }
}

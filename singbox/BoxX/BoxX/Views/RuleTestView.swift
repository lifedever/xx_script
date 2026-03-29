import SwiftUI

struct RuleTestView: View {
    let api: ClashAPI

    @State private var domain = ""
    @State private var isTesting = false
    @State private var results: [RuleTestResult] = []

    var body: some View {
        VStack(spacing: 0) {
            // Input bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "ruletest.placeholder"), text: $domain)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .onSubmit { Task { await runTest() } }

                if isTesting {
                    ProgressView().scaleEffect(0.7)
                }

                Button(String(localized: "ruletest.button")) {
                    Task { await runTest() }
                }
                .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)

                if !results.isEmpty {
                    Button(String(localized: "ruletest.clear")) {
                        results.removeAll()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.bar)

            Divider()

            // Results
            if results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "ruletest.hint"))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "ruletest.hint_detail"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(results.indices, id: \.self) { i in
                            RuleTestResultCard(result: results[i], index: i + 1)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func runTest() async {
        var input = domain.trimmingCharacters(in: .whitespaces)
        input = input.replacingOccurrences(of: "https://", with: "")
        input = input.replacingOccurrences(of: "http://", with: "")
        input = input.components(separatedBy: "/").first ?? input
        guard !input.isEmpty else { return }

        isTesting = true
        defer { isTesting = false }

        if let result = await api.testRule(domain: input) {
            results.insert(result, at: 0)
        } else {
            // No result found — add a failure entry
            results.insert(RuleTestResult(
                domain: input,
                rule: String(localized: "ruletest.no_match"),
                outbound: "–",
                chain: "–",
                destinationIP: ""
            ), at: 0)
        }
    }
}

// MARK: - Result Card

struct RuleTestResultCard: View {
    let result: RuleTestResult
    let index: Int

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Header: domain
                HStack {
                    Text("#\(index)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(result.domain)
                        .font(.headline.monospaced())
                    Spacer()
                    if !result.destinationIP.isEmpty {
                        Text(result.destinationIP)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                // Flow diagram
                VStack(alignment: .leading, spacing: 8) {
                    // Rule matched
                    FlowStep(
                        icon: "text.magnifyingglass",
                        color: .blue,
                        title: String(localized: "ruletest.flow.rule"),
                        value: result.rule
                    )

                    FlowArrow()

                    // Outbound
                    FlowStep(
                        icon: "arrow.right.circle.fill",
                        color: .green,
                        title: String(localized: "ruletest.flow.outbound"),
                        value: result.outbound
                    )

                    FlowArrow()

                    // Full chain
                    FlowStep(
                        icon: "point.3.connected.trianglepath.dotted",
                        color: .orange,
                        title: String(localized: "ruletest.flow.chain"),
                        value: result.chain
                    )
                }
                .padding(.leading, 4)
            }
            .padding(8)
        }
    }
}

struct FlowStep: View {
    let icon: String
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

struct FlowArrow: View {
    var body: some View {
        HStack {
            Image(systemName: "arrow.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 20)
        }
        .padding(.leading, 0)
    }
}

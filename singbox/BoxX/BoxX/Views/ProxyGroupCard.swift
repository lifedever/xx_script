import SwiftUI

struct ProxyGroupCard: View {
    let group: ProxyGroup
    let delays: [String: Int]
    let isTesting: Bool
    let onSelect: (String) -> Void
    let onTestLatency: () -> Void

    @State private var isExpanded = false

    private let maxDots = 20

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Header row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(group.type)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    // Test latency button
                    Button {
                        onTestLatency()
                    } label: {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "speedometer")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting)
                    .help("Test latency")

                    // Expand/collapse
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Current selection
                if let now = group.now, !now.isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text(now)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        if let d = delays[now] {
                            delayText(d)
                        }
                    }
                }

                Divider()

                if isExpanded {
                    // Expanded: scrollable list
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(group.displayAll, id: \.self) { node in
                                Button {
                                    onSelect(node)
                                } label: {
                                    HStack {
                                        if group.now == node {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.green)
                                                .font(.caption)
                                                .frame(width: 14)
                                        } else {
                                            Spacer()
                                                .frame(width: 14)
                                        }
                                        Text(node)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Spacer()
                                        if let d = delays[node] {
                                            delayText(d)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 4)
                                }
                                .buttonStyle(.plain)
                                .background(group.now == node ? Color.accentColor.opacity(0.08) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                } else {
                    // Collapsed: node dots
                    let dots = Array(group.displayAll.prefix(maxDots))
                    HStack(spacing: 4) {
                        ForEach(dots, id: \.self) { node in
                            Circle()
                                .fill(dotColor(for: node))
                                .frame(width: 8, height: 8)
                                .help(node)
                        }
                        if group.displayAll.count > maxDots {
                            Text("+\(group.displayAll.count - maxDots)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(4)
        }
    }

    private func dotColor(for node: String) -> Color {
        if let d = delays[node] {
            if d == 0 { return .red }
            if d < 150 { return .green }
            if d < 400 { return .yellow }
            return .orange
        }
        return Color.secondary.opacity(0.4)
    }

    @ViewBuilder
    private func delayText(_ delay: Int) -> some View {
        Text(delay == 0 ? String(localized: "proxies.timeout") : "\(delay) ms")
            .font(.caption.monospacedDigit())
            .foregroundStyle(delay == 0 ? .red : delay < 150 ? .green : delay < 400 ? .yellow : .orange)
    }
}

import SwiftUI

struct SubscriptionUpdateLogView: View {
    @State private var logs: [String] = []
    @State private var failedSub: Subscription?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("更新日志")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    logs.removeAll()
                    failedSub = nil
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if logs.isEmpty {
                Spacer()
                Text("等待更新...")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                logContent
            }

            if let sub = failedSub {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(verbatim: "\(sub.name) 更新失败")
                        .font(.caption)
                    Spacer()
                    Button("重试") {
                        failedSub = nil
                        NotificationCenter.default.post(name: .subscriptionRetry, object: sub)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
                .padding(8)
                .background(.bar)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .subscriptionLogStart)) { _ in
            logs.removeAll()
            failedSub = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .subscriptionLogAppend)) { notif in
            if let line = notif.object as? String {
                logs.append(line)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .subscriptionUpdateFailed)) { notif in
            if let sub = notif.object as? Subscription {
                failedSub = sub
            }
        }
    }

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.body.monospaced())
                            .foregroundStyle(lineColor(line))
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding()
            }
            .onChange(of: logs.count) { _, _ in
                if let last = logs.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("失败") { return .red }
        if line.contains("完成") || line.contains("成功") { return .green }
        return .primary
    }
}

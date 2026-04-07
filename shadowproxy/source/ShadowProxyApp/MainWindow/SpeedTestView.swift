import SwiftUI
import ShadowProxyCore

struct SpeedTestView: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("测全部") { viewModel.testSpeed() }
                    .disabled(viewModel.isTestingSpeed || !viewModel.isRunning)
                if viewModel.isTestingSpeed {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 8)
                    Text("测速中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !viewModel.isRunning {
                    Text("需要先启动代理")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)

            Divider()

            List {
                ForEach(viewModel.proxyNames, id: \.self) { name in
                    HStack {
                        Text(name).font(.system(size: 13))
                        Spacer()
                        if let speed = viewModel.nodeSpeeds[name] {
                            Text(speed < 0 ? "超时" : "\(speed)ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(speed < 0 ? .gray : speed < 100 ? .green : speed < 300 ? .yellow : .red)
                        } else {
                            Text("-")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("测速")
    }
}

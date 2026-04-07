import SwiftUI
import ShadowProxyCore

struct OverviewView: View {
    @ObservedObject var viewModel: ProxyViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    statusCard(title: "状态", value: viewModel.isRunning ? "运行中" : "已停止",
                              color: viewModel.isRunning ? .green : .gray)
                    statusCard(title: "当前节点", value: viewModel.selectedNodes["Proxy"] ?? "-", color: .blue)
                    if let node = viewModel.selectedNodes["Proxy"], let speed = viewModel.nodeSpeeds[node] {
                        statusCard(title: "延迟", value: "\(speed)ms",
                                  color: speed < 100 ? .green : speed < 300 ? .yellow : .red)
                    } else {
                        statusCard(title: "延迟", value: "-", color: .gray)
                    }
                    statusCard(title: "规则", value: "\(viewModel.ruleCount)", color: .purple)
                }
                Text("服务分流").font(.headline)
                let serviceGroups = viewModel.proxyGroups.filter { $0.name != "Proxy" }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(serviceGroups, id: \.name) { group in
                        HStack {
                            Text(group.name).foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.selectedNodes[group.name] ?? "-").foregroundStyle(.blue).lineLimit(1)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("概览")
    }
    private func statusCard(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

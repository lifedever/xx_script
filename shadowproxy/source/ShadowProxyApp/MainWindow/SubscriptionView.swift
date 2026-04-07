import SwiftUI
import ShadowProxyCore

struct SubscriptionView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("添加订阅") { showingAdd = true }
                Button("刷新全部") { Task { await viewModel.refreshAllSubscriptions() } }
                Spacer()
            }
            .padding(12)

            Divider()

            if viewModel.subscriptions.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无订阅").foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(viewModel.subscriptions) { sub in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sub.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(sub.url)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text("\(sub.nodeCount) 节点")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    if let date = sub.lastUpdate {
                                        Text("更新于 \(date, format: .dateTime.month().day().hour().minute())")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Button("刷新") { Task { await viewModel.refreshSubscription(id: sub.id) } }
                                .controlSize(.small)
                            Button("删除") { viewModel.deleteSubscription(id: sub.id) }
                                .controlSize(.small)
                                .tint(.red)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("订阅")
        .sheet(isPresented: $showingAdd) {
            VStack(spacing: 16) {
                Text("添加订阅").font(.headline)
                TextField("名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                TextField("订阅 URL", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("取消") {
                        showingAdd = false
                        newName = ""
                        newURL = ""
                    }
                    Spacer()
                    Button("确认") {
                        Task { await viewModel.addSubscription(name: newName, url: newURL) }
                        showingAdd = false
                        newName = ""
                        newURL = ""
                    }
                    .disabled(newName.isEmpty || newURL.isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 400)
        }
    }
}

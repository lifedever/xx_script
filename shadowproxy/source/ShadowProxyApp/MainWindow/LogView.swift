import SwiftUI

struct LogView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var searchText = ""
    @State private var autoScroll = true

    var filteredLogs: [String] {
        searchText.isEmpty ? viewModel.logMessages :
            viewModel.logMessages.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Text("\(viewModel.logMessages.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("清除") { viewModel.logMessages.removeAll() }
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filteredLogs.enumerated()), id: \.offset) { index, msg in
                            Text(msg)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 1)
                                .id(index)
                        }
                    }
                }
                .onChange(of: viewModel.logMessages.count) { _, _ in
                    if autoScroll, let last = filteredLogs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .searchable(text: $searchText, prompt: "搜索日志")
        .navigationTitle("日志")
    }
}

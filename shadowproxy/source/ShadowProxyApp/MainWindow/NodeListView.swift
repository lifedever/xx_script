import SwiftUI
import ShadowProxyCore

struct NodeListView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var searchText = ""

    var filteredNodes: [String] {
        searchText.isEmpty ? viewModel.proxyNames :
            viewModel.proxyNames.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredNodes, id: \.self) { name in
                HStack {
                    Text(name).font(.system(size: 13))
                    Spacer()
                    if let speed = viewModel.nodeSpeeds[name] {
                        Text(speed < 0 ? "超时" : "\(speed)ms")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(speed < 0 ? .gray : speed < 100 ? .green : speed < 300 ? .yellow : .red)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .searchable(text: $searchText, prompt: "搜索节点")
        .navigationTitle("节点列表")
    }
}

import SwiftUI
import ShadowProxyCore

struct ProxyGroupsView: View {
    @ObservedObject var viewModel: ProxyViewModel
    var body: some View {
        List {
            ForEach(viewModel.proxyGroups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.name).font(.system(.body, weight: .medium))
                    Picker("", selection: Binding(
                        get: { viewModel.selectedNodes[group.name] ?? group.members.first ?? "" },
                        set: { viewModel.selectNode(group: group.name, node: $0) }
                    )) {
                        ForEach(group.members, id: \.self) { member in
                            HStack {
                                Text(member)
                                Spacer()
                                if let speed = viewModel.nodeSpeeds[member] {
                                    Text("\(speed)ms").font(.caption)
                                        .foregroundStyle(speed < 100 ? .green : speed < 300 ? .yellow : .red)
                                }
                            }.tag(member)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("策略组")
    }
}

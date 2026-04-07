import SwiftUI
import ShadowProxyCore

struct ContentView: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 顶部状态栏
            HStack {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)

                Text(viewModel.isRunning ? viewModel.statusText : "已停止")
                    .font(.headline)

                if viewModel.configLoaded {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.proxyNames.count) 节点")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.ruleCount) 规则")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(viewModel.isRunning ? "停止" : "启动") {
                    if viewModel.isRunning {
                        viewModel.stop()
                    } else {
                        viewModel.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isRunning ? .red : .green)
                .disabled(!viewModel.configLoaded)
            }
            .padding()
            .background(.bar)

            Divider()

            // 主内容
            HSplitView {
                // 左侧：策略组
                groupsPanel
                    .frame(minWidth: 200)

                // 右侧：日志
                logPanel
                    .frame(minWidth: 280)
            }
        }
        .onAppear {
            viewModel.loadConfig()
        }
    }

    // MARK: - 策略组面板

    private var groupsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("策略组")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if viewModel.proxyGroups.isEmpty {
                VStack {
                    Spacer()
                    Text("未加载配置")
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(viewModel.proxyGroups, id: \.name) { group in
                        groupRow(group)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func groupRow(_ group: ProxyGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name)
                .font(.system(.body, weight: .medium))

            Picker("", selection: Binding(
                get: { viewModel.selectedNodes[group.name] ?? group.members.first ?? "" },
                set: { viewModel.selectNode(group: group.name, node: $0) }
            )) {
                ForEach(group.members, id: \.self) { member in
                    Text(member).tag(member)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    // MARK: - 日志面板

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("日志")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清除") {
                    viewModel.logMessages.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(viewModel.logMessages.enumerated()), id: \.offset) { index, msg in
                            Text(msg)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .onChange(of: viewModel.logMessages.count) { _, _ in
                    if let last = viewModel.logMessages.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

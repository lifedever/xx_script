import SwiftUI
import ShadowProxyCore

struct RequestViewerWindow: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var searchText = ""
    @State private var filter: RequestFilter = .all
    @State private var isPaused = false

    enum RequestFilter: String, CaseIterable {
        case all = "全部", proxy = "代理", direct = "直连"
    }

    var filteredRecords: [RequestRecord] {
        var records = viewModel.requestRecords
        switch filter {
        case .proxy: records = records.filter { $0.policy != "DIRECT" }
        case .direct: records = records.filter { $0.policy == "DIRECT" }
        case .all: break
        }
        if !searchText.isEmpty {
            records = records.filter { $0.host.localizedCaseInsensitiveContains(searchText) }
        }
        return records
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            header
            Divider()
            requestList
            Divider()
            statusBar
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(RequestFilter.allCases, id: \.self) { f in
                Button(f.rawValue) { filter = f }
                    .buttonStyle(.bordered)
                    .tint(filter == f ? .accentColor : .gray)
                    .controlSize(.small)
            }
            Spacer()
            TextField("搜索域名...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .controlSize(.small)
            Button(isPaused ? "继续" : "暂停") { isPaused.toggle() }
                .controlSize(.small)
            Button("清除") { viewModel.requestRecords.removeAll() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("时间").frame(width: 70, alignment: .leading)
            Text("协议").frame(width: 55, alignment: .leading)
            Text("域名").frame(maxWidth: .infinity, alignment: .leading)
            Text("策略").frame(width: 110, alignment: .leading)
            Text("耗时").frame(width: 55, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.quaternary.opacity(0.3))
    }

    private var requestList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredRecords) { record in
                        RequestRowView(record: record)
                    }
                }
            }
            .onChange(of: viewModel.requestRecords.count) { _, _ in
                if !isPaused, let last = filteredRecords.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            let total = viewModel.requestRecords.count
            let proxied = viewModel.requestRecords.filter { $0.policy != "DIRECT" }.count
            Text("\(total) 请求 · \(proxied) 代理 · \(total - proxied) 直连")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(isPaused ? "已暂停" : "实时")
                .font(.system(size: 10)).foregroundStyle(isPaused ? .orange : .green)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

private struct RequestRowView: View {
    let record: RequestRecord

    var body: some View {
        HStack(spacing: 0) {
            Text(record.timestamp, format: .dateTime.hour().minute().second())
                .frame(width: 70, alignment: .leading)
            protocolText
            Text(record.host)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            policyText
            elapsedText
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12).padding(.vertical, 3)
        .id(record.id)
    }

    private var protocolText: some View {
        Text(record.requestProtocol)
            .frame(width: 55, alignment: .leading)
            .foregroundStyle(record.requestProtocol == "HTTPS" ? .orange : .green)
    }

    private var policyText: some View {
        Text(record.policy)
            .frame(width: 110, alignment: .leading)
            .foregroundColor(record.policy == "DIRECT" ? .gray : .blue)
            .lineLimit(1)
    }

    @ViewBuilder
    private var elapsedText: some View {
        if let ms = record.elapsed {
            Text("\(ms)ms")
                .frame(width: 55, alignment: .trailing)
                .foregroundStyle(elapsedColor(ms))
        } else {
            Text("-")
                .frame(width: 55, alignment: .trailing)
                .foregroundStyle(.tertiary)
        }
    }

    private func elapsedColor(_ ms: Int) -> Color {
        if ms < 100 { return .green }
        if ms < 300 { return .yellow }
        return .red
    }
}

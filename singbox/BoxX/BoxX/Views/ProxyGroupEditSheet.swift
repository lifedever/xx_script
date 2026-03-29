// BoxX/Views/ProxyGroupEditSheet.swift
import SwiftUI

struct ProxyGroupEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let existingTag: String?  // nil = create new, non-nil = edit existing

    @State private var tag: String = ""
    @State private var groupType: String = "selector"  // selector, urltest
    @State private var selectedOutbounds: [String] = []
    @State private var testURL: String = "https://www.gstatic.com/generate_204"
    @State private var testInterval: String = "300s"
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingTag != nil ? "编辑策略组" : "新建策略组")
                .font(.headline)

            // Name
            HStack {
                Text("名称")
                    .frame(width: 80, alignment: .leading)
                TextField("例如: 📺YouTube", text: $tag)
                    .textFieldStyle(.roundedBorder)
                    .disabled(existingTag != nil)
            }

            // Type picker
            HStack {
                Text("类型")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $groupType) {
                    Text("手动选择 (selector)").tag("selector")
                    Text("自动测速 (url-test)").tag("urltest")
                }
                .labelsHidden()
            }

            // URL test settings (only for urltest)
            if groupType == "urltest" {
                HStack {
                    Text("测试 URL")
                        .frame(width: 80, alignment: .leading)
                    TextField("https://...", text: $testURL)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("测试间隔")
                        .frame(width: 80, alignment: .leading)
                    TextField("300s", text: $testInterval)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }

            // Outbounds selection
            Text("包含的出站（节点/策略组）")
                .font(.subheadline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    // Section: Strategy groups (other selector/urltest groups, excluding self)
                    let groups = allSelectorTags.filter { $0 != tag }
                    if !groups.isEmpty {
                        Text("策略组").font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .padding(.leading, 8)
                        ForEach(groups, id: \.self) { name in
                            outboundCheckbox(name)
                        }
                    }

                    // Section: Special
                    Text("特殊").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .padding(.leading, 8)
                    outboundCheckbox("DIRECT")

                    // Section: Proxy nodes (from proxies/)
                    let nodes = allProxyNodeTags
                    if !nodes.isEmpty {
                        Text("代理节点").font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .padding(.leading, 8)
                        ForEach(nodes, id: \.self) { name in
                            outboundCheckbox(name)
                        }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 300)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Divider()

            HStack {
                if existingTag != nil {
                    Button("删除", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { saveGroup(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tag.isEmpty || selectedOutbounds.isEmpty)
            }
        }
        .padding()
        .frame(width: 450, height: 550)
        .onAppear { loadExisting() }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteGroup(); dismiss() }
        } message: {
            Text("确定要删除策略组「\(tag)」吗？此操作不可撤销。")
        }
    }

    private func outboundCheckbox(_ name: String) -> some View {
        let isSelected = selectedOutbounds.contains(name)
        return Button {
            if isSelected {
                selectedOutbounds.removeAll { $0 == name }
            } else {
                selectedOutbounds.append(name)
            }
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(name)
                    .font(.body)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var allSelectorTags: [String] {
        appState.configEngine.config.outbounds.compactMap {
            switch $0 {
            case .selector(let s): return s.tag
            case .urltest(let u): return u.tag
            default: return nil
            }
        }
    }

    private var allProxyNodeTags: [String] {
        appState.configEngine.proxies.values.flatMap { $0 }.map { $0.tag }
    }

    private func loadExisting() {
        guard let existingTag else { return }
        tag = existingTag
        if let idx = appState.configEngine.config.outbounds.firstIndex(where: { $0.tag == existingTag }) {
            switch appState.configEngine.config.outbounds[idx] {
            case .selector(let s):
                groupType = "selector"
                selectedOutbounds = s.outbounds
            case .urltest(let u):
                groupType = "urltest"
                selectedOutbounds = u.outbounds
                testURL = u.url ?? "https://www.gstatic.com/generate_204"
                testInterval = u.interval ?? "300s"
            default: break
            }
        }
    }

    private func saveGroup() {
        let outbound: Outbound
        if groupType == "urltest" {
            outbound = .urltest(URLTestOutbound(tag: tag, outbounds: selectedOutbounds, url: testURL, interval: testInterval))
        } else {
            outbound = .selector(SelectorOutbound(tag: tag, outbounds: selectedOutbounds))
        }

        if let existingTag,
           let idx = appState.configEngine.config.outbounds.firstIndex(where: { $0.tag == existingTag }) {
            appState.configEngine.config.outbounds[idx] = outbound
        } else {
            appState.configEngine.config.outbounds.append(outbound)
        }

        try? appState.configEngine.save(restartRequired: true)
    }

    private func deleteGroup() {
        guard let existingTag else { return }
        appState.configEngine.config.outbounds.removeAll { $0.tag == existingTag }
        try? appState.configEngine.save(restartRequired: true)
    }
}

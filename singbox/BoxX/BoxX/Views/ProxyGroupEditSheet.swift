// BoxX/Views/ProxyGroupEditSheet.swift
import SwiftUI

enum OutboundMode: String, CaseIterable {
    case manual = "手动设置"
    case keyword = "关键词匹配"
    case regex = "正则匹配"
}

struct ProxyGroupEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let existingTag: String?

    @State private var tag: String = ""
    @State private var groupType: String = "selector"
    @State private var selectedOutbounds: [String] = []
    @State private var testURL: String = "https://www.gstatic.com/generate_204"
    @State private var testInterval: String = "300s"
    @State private var showDeleteConfirmation = false
    @State private var outboundMode: OutboundMode = .manual
    @State private var matchPatternsText: String = ""

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
            }

            // Type
            HStack {
                Text("类型")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $groupType) {
                    Text("手动选择 (selector)").tag("selector")
                    Text("自动测速 (url-test)").tag("urltest")
                }
                .labelsHidden()
            }

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

            Divider()

            // Outbound mode: 三选一
            HStack {
                Text("节点来源")
                    .font(.subheadline.bold())
                Spacer()
                Picker("", selection: $outboundMode) {
                    ForEach(OutboundMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }

            // Mode-specific content
            switch outboundMode {
            case .manual:
                manualSelectionView

            case .keyword:
                VStack(alignment: .leading, spacing: 6) {
                    TextField("关键词，用逗号分隔（如: 香港,HK,Hong Kong）", text: $matchPatternsText)
                        .textFieldStyle(.roundedBorder)
                    Text("订阅更新时，节点名包含任一关键词将自动加入此策略组")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    matchPreview
                }

            case .regex:
                VStack(alignment: .leading, spacing: 6) {
                    TextField("正则表达式（如: 香港|HK|Hong\\s?Kong）", text: $matchPatternsText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Text("订阅更新时，节点名匹配正则的将自动加入此策略组")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    matchPreview
                }
            }

            Divider()

            // Buttons
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
                    .disabled(tag.isEmpty || (outboundMode == .manual && selectedOutbounds.isEmpty))
            }
        }
        .padding()
        .frame(width: 520, height: outboundMode == .manual ? 620 : 420)
        .onAppear { loadExisting() }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteGroup(); dismiss() }
        } message: {
            Text("确定要删除策略组「\(tag)」吗？")
        }
    }

    // MARK: - Manual selection list

    private var manualSelectionView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                let groups = allSelectorTags.filter { $0 != tag }
                if !groups.isEmpty {
                    Text("策略组").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4).padding(.leading, 8)
                    ForEach(groups, id: \.self) { name in
                        outboundCheckbox(name)
                    }
                }

                Text("特殊").font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 4).padding(.leading, 8)
                outboundCheckbox("DIRECT")

                let nodes = allProxyNodeTags
                if !nodes.isEmpty {
                    Text("代理节点").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4).padding(.leading, 8)
                    ForEach(nodes, id: \.self) { name in
                        outboundCheckbox(name)
                    }
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 250)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Match preview (shows which nodes would match)

    private var matchPreview: some View {
        let matched = matchingNodes
        return Group {
            if !matchPatternsText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("匹配预览：\(matched.count) 个节点")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(matched.prefix(20), id: \.self) { node in
                                Text(node)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.green)
                            }
                            if matched.count > 20 {
                                Text("... 还有 \(matched.count - 20) 个")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 120)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var matchingNodes: [String] {
        let allNodes = allProxyNodeTags
        guard !matchPatternsText.isEmpty else { return [] }

        let patterns = matchPatternsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !patterns.isEmpty else { return [] }

        return allNodes.filter { node in
            let lower = node.lowercased()
            switch outboundMode {
            case .keyword:
                return patterns.contains { lower.contains($0.lowercased()) }
            case .regex:
                return patterns.contains { regex in
                    node.range(of: regex, options: .regularExpression) != nil
                }
            case .manual:
                return false
            }
        }
    }

    // MARK: - Checkbox

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
                Text(name).font(.body)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: - Data

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

    // MARK: - Load / Save

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

        // Load match patterns → determine mode
        let patterns = appState.configEngine.loadGroupPatterns()
        if let pattern = patterns[existingTag] {
            outboundMode = pattern.mode == "regex" ? .regex : .keyword
            matchPatternsText = pattern.patterns.joined(separator: ", ")
        } else {
            outboundMode = .manual
        }
    }

    private func saveGroup() {
        if let existingTag, existingTag != tag {
            appState.configEngine.renameGroup(oldTag: existingTag, newTag: tag)
        }

        // For keyword/regex mode, build outbounds from matched nodes
        let finalOutbounds: [String]
        if outboundMode == .manual {
            finalOutbounds = selectedOutbounds
        } else {
            finalOutbounds = matchingNodes
        }

        let outbound: Outbound
        if groupType == "urltest" {
            outbound = .urltest(URLTestOutbound(tag: tag, outbounds: finalOutbounds, url: testURL, interval: testInterval))
        } else {
            outbound = .selector(SelectorOutbound(tag: tag, outbounds: finalOutbounds))
        }

        if let idx = appState.configEngine.config.outbounds.firstIndex(where: { $0.tag == tag }) {
            appState.configEngine.config.outbounds[idx] = outbound
        } else if let existingTag,
                  let idx = appState.configEngine.config.outbounds.firstIndex(where: { $0.tag == existingTag }) {
            appState.configEngine.config.outbounds[idx] = outbound
        } else {
            appState.configEngine.config.outbounds.append(outbound)
        }

        // Save/remove pattern
        var patterns = appState.configEngine.loadGroupPatterns()
        if outboundMode != .manual && !matchPatternsText.isEmpty {
            let patternList = matchPatternsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            patterns[tag] = GroupPattern(mode: outboundMode == .regex ? "regex" : "keyword", patterns: patternList)
        } else {
            patterns.removeValue(forKey: tag)
        }
        appState.configEngine.saveGroupPatterns(patterns)

        try? appState.configEngine.save(restartRequired: true)
    }

    private func deleteGroup() {
        guard let existingTag else { return }
        appState.configEngine.config.outbounds.removeAll { $0.tag == existingTag }
        var patterns = appState.configEngine.loadGroupPatterns()
        patterns.removeValue(forKey: existingTag)
        appState.configEngine.saveGroupPatterns(patterns)
        try? appState.configEngine.save(restartRequired: true)
    }
}

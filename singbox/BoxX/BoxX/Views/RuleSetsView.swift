import SwiftUI

struct RuleSetsView: View {
    @Environment(AppState.self) private var appState

    @State private var ruleSetUpdateStatus: [String: RuleSetUpdateStatus] = [:]
    @State private var selectedRuleSetIndex: Int?
    @State private var editingRuleSetTag: String?
    @State private var editingOutbound: String = ""
    @State private var deletingTag: String?
    @State private var deletingIndex: Int?

    enum RuleSetUpdateStatus {
        case idle
        case updating
        case success
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("规则集")
                    .font(.title2)
                    .bold()
                let ruleSets = appState.configEngine.config.route.ruleSet ?? []
                Text("\(ruleSets.count) 个规则集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                let hasRemote = ruleSets.contains { $0["type"]?.stringValue == "remote" }
                if hasRemote {
                    Button {
                        Task { await updateAllRemoteRuleSets() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("全部更新")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(ruleSetUpdateStatus.values.contains { if case .updating = $0 { return true } else { return false } })
                }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Filter out rule sets managed by 内置规则 page
                    let builtinGeositeTags = Set(BuiltinRuleSet.all.flatMap { $0.geositeNames }.map { "geosite-\($0)" })
                    let ruleSets = (appState.configEngine.config.route.ruleSet ?? [])
                        .filter { item in
                            guard let tag = item["tag"]?.stringValue else { return true }
                            return !builtinGeositeTags.contains(tag)
                        }
                    if ruleSets.isEmpty {
                        Text("暂无规则集")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        // Table header
                        HStack(spacing: 0) {
                            Text("#")
                                .frame(width: 30, alignment: .leading)
                            Text("标签")
                                .frame(width: 180, alignment: .leading)
                            Text("类型")
                                .frame(width: 70, alignment: .leading)
                            Text("URL/路径")
                                .frame(minWidth: 160, alignment: .leading)
                            Spacer()
                            Text("格式")
                                .frame(width: 60, alignment: .leading)
                            Text("出站")
                                .frame(width: 100, alignment: .leading)
                            Text("操作")
                                .frame(width: 160, alignment: .center)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)

                        LazyVStack(spacing: 0) {
                            ForEach(Array(ruleSets.enumerated()), id: \.offset) { index, ruleSet in
                                configuredRuleSetRow(index: index, ruleSet: ruleSet)
                            }
                        }
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding()
            }
        }
        .sheet(item: Binding(
            get: { editingRuleSetTag.map { EditingTag(tag: $0) } },
            set: { editingRuleSetTag = $0?.tag }
        )) { item in
            RuleSetEditSheet(
                tag: item.tag,
                currentOutbound: outboundForRuleSet(tag: item.tag) ?? "Proxy",
                availableOutbounds: availableOutbounds,
                onSave: { newOutbound in
                    changeOutbound(forRuleSetTag: item.tag, to: newOutbound)
                    editingRuleSetTag = nil
                },
                onCancel: { editingRuleSetTag = nil }
            )
        }
        .alert("确认删除", isPresented: .init(
            get: { deletingTag != nil },
            set: { if !$0 { deletingTag = nil; deletingIndex = nil } }
        )) {
            Button("取消", role: .cancel) { deletingTag = nil; deletingIndex = nil }
            Button("删除", role: .destructive) {
                if let idx = deletingIndex, let tag = deletingTag {
                    deleteRuleSet(at: idx, tag: tag)
                }
                deletingTag = nil
                deletingIndex = nil
            }
        } message: {
            Text("确定要删除规则集「\(deletingTag ?? "")」吗？")
        }
    }

    // MARK: - Sheet ID wrapper

    private struct EditingTag: Identifiable {
        let tag: String
        var id: String { tag }
    }

    // MARK: - Row View

    private func configuredRuleSetRow(index: Int, ruleSet: JSONValue) -> some View {
        let tag = ruleSet["tag"]?.stringValue ?? "unknown"
        let type = ruleSet["type"]?.stringValue ?? "unknown"
        let format = ruleSet["format"]?.stringValue ?? ""
        let url = ruleSet["url"]?.stringValue
        let path = ruleSet["path"]?.stringValue
        let isRemote = type == "remote"
        let location = url ?? path ?? "—"
        let isSelected = selectedRuleSetIndex == index

        return HStack(spacing: 0) {
            // # column
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            // Tag column
            Text(tag)
                .font(.body.monospaced())
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            // Type badge column
            Text(type)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(type == "local" ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                .foregroundStyle(type == "local" ? Color.green : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 70, alignment: .leading)

            // URL/Path column
            Text(location)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 160, alignment: .leading)
                .help(location)

            Spacer()

            // Format column
            Text(format)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)

            // Outbound column (plain text, no picker)
            Group {
                let currentOutbound = outboundForRuleSet(tag: tag)
                if let outbound = currentOutbound {
                    Text(outbound)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未关联")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 100, alignment: .leading)

            // 操作按钮
            HStack(spacing: 6) {
                Button("编辑") {
                    editingOutbound = outboundForRuleSet(tag: tag) ?? availableOutbounds.first ?? "Proxy"
                    editingRuleSetTag = tag
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("删除") {
                    deletingTag = tag
                    deletingIndex = index
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                if isRemote {
                    if let status = ruleSetUpdateStatus[tag] {
                        switch status {
                        case .updating:
                            ProgressView().controlSize(.small)
                        case .success:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed:
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        case .idle:
                            Button("更新") {
                                Task { await updateRuleSet(tag: tag, url: url ?? "") }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Button("更新") {
                            Task { await updateRuleSet(tag: tag, url: url ?? "") }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .frame(width: 160, alignment: .center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                : (index % 2 == 0 ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial.opacity(0.5)))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRuleSetIndex = (selectedRuleSetIndex == index) ? nil : index
        }
        .contextMenu {
            Button {
                editingOutbound = outboundForRuleSet(tag: tag) ?? availableOutbounds.first ?? "Proxy"
                editingRuleSetTag = tag
            } label: {
                Label("编辑出站", systemImage: "pencil")
            }
            if isRemote, let url = url {
                Button {
                    Task { await updateRuleSet(tag: tag, url: url) }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                deleteRuleSet(at: index, tag: tag)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func ruleSetRefreshButton(tag: String, url: String?, isRemote: Bool) -> some View {
        if isRemote, let url = url {
            Button {
                Task { await updateRuleSet(tag: tag, url: url) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("更新规则集")
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    // MARK: - Delete

    private func deleteRuleSet(at index: Int, tag: String) {
        // Remove from route.rule_set
        var ruleSets = appState.configEngine.config.route.ruleSet ?? []
        guard index >= 0 && index < ruleSets.count else { return }
        ruleSets.remove(at: index)
        appState.configEngine.config.route.ruleSet = ruleSets

        // Also remove any route.rules referencing this rule_set tag
        var rules = appState.configEngine.config.route.rules ?? []
        rules.removeAll { rule in
            guard let refs = rule["rule_set"]?.arrayValue else { return false }
            let tags = refs.compactMap { $0.stringValue }
            return tags == [tag]
        }
        appState.configEngine.config.route.rules = rules

        do {
            try appState.configEngine.save(restartRequired: true)
        } catch {
            appState.showAlert("删除失败: \(error.localizedDescription)")
        }
        selectedRuleSetIndex = nil
    }

    // MARK: - Outbound Helpers

    private var availableOutbounds: [String] {
        var result = appState.configEngine.config.outbounds.compactMap { outbound -> String? in
            switch outbound {
            case .selector(let s): return s.tag
            case .direct(let d): return d.tag
            default: return nil
            }
        }
        result.append("REJECT")
        return result
    }

    private func outboundForRuleSet(tag: String) -> String? {
        let rules = appState.configEngine.config.route.rules ?? []
        for rule in rules {
            guard let ruleSetRefs = rule["rule_set"]?.arrayValue else { continue }
            let tags = ruleSetRefs.compactMap { $0.stringValue }
            if tags.contains(tag) {
                // Check for reject action
                if rule["action"]?.stringValue == "reject" { return "REJECT" }
                return rule["outbound"]?.stringValue
            }
        }
        return nil
    }

    private func changeOutbound(forRuleSetTag tag: String, to newOutbound: String) {
        var rules = appState.configEngine.config.route.rules ?? []
        var found = false
        for i in rules.indices {
            guard let ruleSetRefs = rules[i]["rule_set"]?.arrayValue else { continue }
            let tags = ruleSetRefs.compactMap { $0.stringValue }
            if tags.contains(tag) {
                if case .object(var dict) = rules[i] {
                    if newOutbound == "REJECT" {
                        dict["action"] = .string("reject")
                        dict.removeValue(forKey: "outbound")
                    } else {
                        dict["action"] = .string("route")
                        dict["outbound"] = .string(newOutbound)
                    }
                    rules[i] = .object(dict)
                }
                found = true
                break
            }
        }
        // If no existing rule references this tag, create one
        if !found {
            var ruleDict: [String: JSONValue] = [
                "rule_set": .array([.string(tag)]),
            ]
            if newOutbound == "REJECT" {
                ruleDict["action"] = .string("reject")
            } else {
                ruleDict["action"] = .string("route")
                ruleDict["outbound"] = .string(newOutbound)
            }
            rules.append(.object(ruleDict))
        }
        appState.configEngine.config.route.rules = rules
        try? appState.configEngine.save(restartRequired: true)
    }

    // MARK: - Rule Set Update

    private func updateRuleSet(tag: String, url: String) async {
        ruleSetUpdateStatus[tag] = .updating
        do {
            let ruleSetManager = RuleSetManager(rulesDir: appState.configEngine.baseDir.appendingPathComponent("rules"))
            guard let remoteURL = URL(string: url) else {
                ruleSetUpdateStatus[tag] = .failed("无效的 URL")
                return
            }
            let ext = url.hasSuffix(".srs") ? "srs" : "json"
            _ = try await ruleSetManager.downloadRuleSet(url: remoteURL, filename: "\(tag).\(ext)")
            ruleSetUpdateStatus[tag] = .success
        } catch {
            ruleSetUpdateStatus[tag] = .failed(error.localizedDescription)
        }
    }

    private func updateAllRemoteRuleSets() async {
        let remoteSets = (appState.configEngine.config.route.ruleSet ?? [])
            .filter { $0["type"]?.stringValue == "remote" }

        for rs in remoteSets {
            guard let tag = rs["tag"]?.stringValue,
                  let url = rs["url"]?.stringValue else { continue }
            await updateRuleSet(tag: tag, url: url)
        }
    }
}

// MARK: - Rule Set Edit Sheet

struct RuleSetEditSheet: View {
    let tag: String
    @State var currentOutbound: String
    let availableOutbounds: [String]
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑规则集")
                .font(.headline)

            HStack {
                Text("规则集")
                    .frame(width: 80, alignment: .leading)
                Text(tag)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("出站策略")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $currentOutbound) {
                    ForEach(availableOutbounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { onSave(currentOutbound) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

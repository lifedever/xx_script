import SwiftUI

struct RuleSetsView: View {
    @Environment(AppState.self) private var appState

    @State private var ruleSetUpdateStatus: [String: RuleSetUpdateStatus] = [:]
    @State private var selectedRuleSetIndex: Int?
    @State private var editingRuleSet: JSONValue?  // nil = not editing, non-nil = editing this rule set
    @State private var showingAddSheet = false
    @State private var viewingRuleSet: JSONValue?  // for content viewing
    @State private var deletingTag: String?
    @State private var deletingIndex: Int?

    enum RuleSetUpdateStatus {
        case idle
        case updating
        case success(Date)
        case failed(String)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("规则集")
                    .font(.title2)
                    .bold()
                let ruleSets = appState.configEngine.config.route.ruleSet ?? []
                Text("\(ruleSets.count) 个规则集")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("新增")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                let hasRemote = ruleSets.contains { $0["type"]?.stringValue == "remote" }
                if hasRemote {
                    Button {
                        Task { await forceUpdateRuleSets() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("全部更新")
                        }
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
                            Text("更新时间")
                                .frame(width: 70, alignment: .trailing)
                            Text("操作")
                                .frame(width: 200, alignment: .center)
                        }
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)

                        LazyVStack(spacing: 0) {
                            ForEach(Array(ruleSets.enumerated()), id: \.offset) { index, ruleSet in
                                configuredRuleSetRow(index: index, ruleSet: ruleSet)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            RuleSetFormSheet(
                mode: .add,
                availableOutbounds: availableOutbounds,
                existingTags: allRuleSetTags,
                currentOutbound: nil,
                onSave: { ruleSetDef, outbound in
                    addRuleSet(ruleSetDef, outbound: outbound)
                    showingAddSheet = false
                },
                onCancel: { showingAddSheet = false }
            )
        }
        .sheet(item: Binding(
            get: { editingRuleSet.map { EditingRuleSet(ruleSet: $0) } },
            set: { editingRuleSet = $0?.ruleSet }
        )) { item in
            RuleSetFormSheet(
                mode: .edit(item.ruleSet),
                availableOutbounds: availableOutbounds,
                existingTags: allRuleSetTags,
                currentOutbound: outboundForRuleSet(tag: item.ruleSet["tag"]?.stringValue ?? ""),
                onSave: { ruleSetDef, outbound in
                    updateRuleSetDef(ruleSetDef, outbound: outbound)
                    editingRuleSet = nil
                },
                onCancel: { editingRuleSet = nil }
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
        .sheet(item: Binding(
            get: { viewingRuleSet.map { ViewingRuleSet(ruleSet: $0) } },
            set: { viewingRuleSet = $0?.ruleSet }
        )) { item in
            RuleSetContentView(
                ruleSet: item.ruleSet,
                rulesDir: appState.configEngine.baseDir.appendingPathComponent("rules"),
                onClose: { viewingRuleSet = nil }
            )
        }
    }

    private struct ViewingRuleSet: Identifiable {
        let ruleSet: JSONValue
        var id: String { ruleSet["tag"]?.stringValue ?? UUID().uuidString }
    }

    // MARK: - Sheet ID wrapper

    private struct EditingRuleSet: Identifiable {
        let ruleSet: JSONValue
        var id: String { ruleSet["tag"]?.stringValue ?? UUID().uuidString }
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
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            // Tag column
            Text(tag)
                .monospaced()
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            // Type badge column
            Text(type)
                .monospaced()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(type == "local" ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                .foregroundStyle(type == "local" ? Color.green : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 70, alignment: .leading)

            // URL/Path column
            Text(location)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 160, alignment: .leading)
                .help(location)

            Spacer()

            // Format column
            Text(format)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)

            // Outbound column (plain text, no picker)
            Group {
                let currentOutbound = outboundForRuleSet(tag: tag)
                if let outbound = currentOutbound {
                    Text(outbound)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未关联")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 100, alignment: .leading)

            // 文件更新时间
            if isRemote {
                let ext = format == "binary" ? "srs" : "json"
                let filePath = appState.configEngine.baseDir
                    .appendingPathComponent("rules/\(tag).\(ext)").path
                let mtime = (try? FileManager.default.attributesOfItem(atPath: filePath))?[.modificationDate] as? Date
                Text(mtime.map { Self.dateTimeFormatter.string(from: $0) } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .trailing)
            } else {
                Spacer().frame(width: 70)
            }

            // 操作按钮
            HStack(spacing: 6) {
                Button("查看") {
                    viewingRuleSet = ruleSet
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("编辑") {
                    editingRuleSet = ruleSet
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if isRemote {
                    Button("更新") {
                        Task { await updateSingleRuleSet(ruleSet) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.blue)
                    .disabled(ruleSetUpdateStatus[tag].map { if case .updating = $0 { return true } else { return false } } ?? false)
                }

                Button("删除") {
                    deletingTag = tag
                    deletingIndex = index
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                if isRemote, let status = ruleSetUpdateStatus[tag] {
                    switch status {
                    case .updating:
                        ProgressView().controlSize(.small)
                    case .success(let date):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("更新于 \(Self.timeFormatter.string(from: date))")
                    case .failed(let msg):
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help(msg)
                    case .idle:
                        EmptyView()
                    }
                }
            }
            .frame(width: 200, alignment: .center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                : (index % 2 == 0 ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Color.gray.opacity(0.06)))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRuleSetIndex = (selectedRuleSetIndex == index) ? nil : index
        }
        .contextMenu {
            Button {
                viewingRuleSet = ruleSet
            } label: {
                Label("查看规则", systemImage: "doc.text.magnifyingglass")
            }
            Button {
                editingRuleSet = ruleSet
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteRuleSet(at: index, tag: tag)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - All Tags

    private var allRuleSetTags: Set<String> {
        Set((appState.configEngine.config.route.ruleSet ?? []).compactMap { $0["tag"]?.stringValue })
    }

    // MARK: - Add

    private func addRuleSet(_ ruleSetDef: JSONValue, outbound: String) {
        var ruleSets = appState.configEngine.config.route.ruleSet ?? []
        ruleSets.append(ruleSetDef)
        appState.configEngine.config.route.ruleSet = ruleSets

        // Create route rule for this rule set
        if let tag = ruleSetDef["tag"]?.stringValue {
            changeOutbound(forRuleSetTag: tag, to: outbound)
        } else {
            try? appState.configEngine.save(restartRequired: true)
        }
    }

    // MARK: - Update Definition

    private func updateRuleSetDef(_ ruleSetDef: JSONValue, outbound: String) {
        guard let tag = ruleSetDef["tag"]?.stringValue else { return }
        var ruleSets = appState.configEngine.config.route.ruleSet ?? []
        if let idx = ruleSets.firstIndex(where: { $0["tag"]?.stringValue == tag }) {
            ruleSets[idx] = ruleSetDef
        }
        appState.configEngine.config.route.ruleSet = ruleSets
        changeOutbound(forRuleSetTag: tag, to: outbound)
    }

    // MARK: - Delete

    private func deleteRuleSet(at index: Int, tag: String) {
        // Remove from route.rule_set
        var ruleSets = appState.configEngine.config.route.ruleSet ?? []
        guard index >= 0 && index < ruleSets.count else { return }
        ruleSets.remove(at: index)
        appState.configEngine.config.route.ruleSet = ruleSets

        // Remove or clean up route.rules referencing this rule_set tag
        var rules = appState.configEngine.config.route.rules ?? []
        var indicesToRemove: [Int] = []
        for i in rules.indices {
            guard case .object(var dict) = rules[i],
                  let refs = dict["rule_set"]?.arrayValue else { continue }
            let tags = refs.compactMap { $0.stringValue }
            if tags.contains(tag) {
                let remaining = tags.filter { $0 != tag }
                if remaining.isEmpty {
                    // This rule only referenced the deleted tag — remove it
                    indicesToRemove.append(i)
                } else {
                    // Remove this tag but keep the rule for other tags
                    dict["rule_set"] = .array(remaining.map { .string($0) })
                    rules[i] = .object(dict)
                }
            }
        }
        for i in indicesToRemove.reversed() {
            rules.remove(at: i)
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

    /// Update a single remote rule set: download (overwrite) → mark pending reload.
    private func updateSingleRuleSet(_ ruleSet: JSONValue) async {
        guard let tag = ruleSet["tag"]?.stringValue,
              let urlStr = ruleSet["url"]?.stringValue,
              let url = URL(string: urlStr) else { return }
        let format = ruleSet["format"]?.stringValue ?? "binary"
        let ext = format == "binary" ? "srs" : "json"
        let rulesDir = appState.configEngine.baseDir.appendingPathComponent("rules")

        ruleSetUpdateStatus[tag] = .updating

        let mgr = RuleSetManager(rulesDir: rulesDir, proxyPort: appState.configEngine.mixedPort)
        do {
            _ = try await mgr.downloadRuleSet(url: url, filename: "\(tag).\(ext)")
            ruleSetUpdateStatus[tag] = .success(Date())
            try? appState.configEngine.deployRuntime(skipValidation: true)
        } catch {
            ruleSetUpdateStatus[tag] = .failed(error.localizedDescription)
        }
    }

    /// Force re-download all remote rule sets.
    private func forceUpdateRuleSets() async {
        let ruleSets = appState.configEngine.config.route.ruleSet ?? []
        let remoteRuleSets = ruleSets.filter { $0["type"]?.stringValue == "remote" }
        let rulesDir = appState.configEngine.baseDir.appendingPathComponent("rules")
        let mgr = RuleSetManager(rulesDir: rulesDir, proxyPort: appState.configEngine.mixedPort)

        for rs in remoteRuleSets {
            guard let tag = rs["tag"]?.stringValue else { continue }
            ruleSetUpdateStatus[tag] = .updating
        }

        for rs in remoteRuleSets {
            guard let tag = rs["tag"]?.stringValue,
                  let urlStr = rs["url"]?.stringValue,
                  let url = URL(string: urlStr) else { continue }
            let format = rs["format"]?.stringValue ?? "binary"
            let ext = format == "binary" ? "srs" : "json"
            do {
                _ = try await mgr.downloadRuleSet(url: url, filename: "\(tag).\(ext)")
                ruleSetUpdateStatus[tag] = .success(Date())
            } catch {
                ruleSetUpdateStatus[tag] = .failed(error.localizedDescription)
            }
        }

        try? appState.configEngine.deployRuntime(skipValidation: true)
    }
}

// MARK: - Rule Set Form Sheet (Add / Edit)

struct RuleSetFormSheet: View {
    enum Mode {
        case add
        case edit(JSONValue)  // existing rule set definition
    }

    let mode: Mode
    let availableOutbounds: [String]
    let existingTags: Set<String>
    let currentOutbound: String?  // for edit mode, the current outbound of this rule set
    let onSave: (JSONValue, String) -> Void  // (ruleSetDef, outbound)
    let onCancel: () -> Void

    @State private var ruleSetType = "remote"
    @State private var tag = ""
    @State private var url = ""
    @State private var path = ""
    @State private var format = "binary"
    @State private var outbound = "Proxy"
    @State private var downloadDetour = "DIRECT"
    @State private var updateIntervalHours = ""
    @State private var validationError: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "编辑规则集" : "新增规则集")
                .font(.headline)

            Form {
                if isEditing {
                    LabeledContent("标签") {
                        Text(tag)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField("标签", text: $tag, prompt: Text("例如: my-rules"))
                        .monospaced()
                }

                Picker("类型", selection: $ruleSetType) {
                    Text("remote").tag("remote")
                    Text("local").tag("local")
                }
                .pickerStyle(.segmented)

                if ruleSetType == "remote" {
                    TextField("URL", text: $url, prompt: Text("https://example.com/rules.srs"))
                        .monospaced()
                } else {
                    TextField("路径", text: $path, prompt: Text("/path/to/rules.json"))
                        .monospaced()
                }

                Picker("格式", selection: $format) {
                    Text("binary").tag("binary")
                    Text("source").tag("source")
                }
                .pickerStyle(.segmented)

                Picker("出站策略", selection: $outbound) {
                    ForEach(availableOutbounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                if ruleSetType == "remote" {
                    Picker("下载出站", selection: $downloadDetour) {
                        ForEach(availableOutbounds.filter({ $0 != "REJECT" }), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }

                    HStack {
                        TextField("更新间隔", text: $updateIntervalHours, prompt: Text("留空使用全局默认"))
                            .frame(width: 160)
                        Text("小时")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let error = validationError {
                Text(error)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500)
        .onAppear { loadFromMode() }
    }

    private func loadFromMode() {
        if let ob = currentOutbound {
            outbound = ob
        }
        guard case .edit(let rs) = mode else { return }
        tag = rs["tag"]?.stringValue ?? ""
        ruleSetType = rs["type"]?.stringValue ?? "remote"
        url = rs["url"]?.stringValue ?? ""
        path = rs["path"]?.stringValue ?? ""
        format = rs["format"]?.stringValue ?? "binary"
        downloadDetour = rs["download_detour"]?.stringValue ?? "DIRECT"
        if let interval = rs["update_interval"]?.stringValue {
            // Parse "24h0m0s" → "24"
            if let match = interval.firstMatch(of: /^(\d+)h/) {
                updateIntervalHours = String(match.1)
            }
        }
    }

    private func save() {
        // Validate
        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)
        if trimmedTag.isEmpty {
            validationError = "标签不能为空"
            return
        }
        if !isEditing && existingTags.contains(trimmedTag) {
            validationError = "标签「\(trimmedTag)」已存在"
            return
        }
        if ruleSetType == "remote" && url.trimmingCharacters(in: .whitespaces).isEmpty {
            validationError = "URL 不能为空"
            return
        }
        if ruleSetType == "local" && path.trimmingCharacters(in: .whitespaces).isEmpty {
            validationError = "路径不能为空"
            return
        }

        // Build JSONValue
        var dict: [String: JSONValue] = [
            "type": .string(ruleSetType),
            "tag": .string(trimmedTag),
            "format": .string(format),
        ]
        if ruleSetType == "remote" {
            dict["url"] = .string(url.trimmingCharacters(in: .whitespaces))
            dict["download_detour"] = .string(downloadDetour)
            if let hours = Int(updateIntervalHours.trimmingCharacters(in: .whitespaces)), hours > 0 {
                dict["update_interval"] = .string("\(hours)h0m0s")
            }
        } else {
            dict["path"] = .string(path.trimmingCharacters(in: .whitespaces))
        }

        onSave(.object(dict), outbound)
    }
}

// MARK: - Rule Set Content Viewer

struct RuleSetContentView: View {
    let ruleSet: JSONValue
    let rulesDir: URL
    let onClose: () -> Void

    @State private var content: String = ""
    @State private var isLoading = true
    @State private var error: String?
    @State private var ruleCount: Int = 0
    @State private var isTruncated = false

    private static let maxDisplayLines = 500

    private var tag: String { ruleSet["tag"]?.stringValue ?? "unknown" }
    private var format: String { ruleSet["format"]?.stringValue ?? "source" }
    private var type: String { ruleSet["type"]?.stringValue ?? "local" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("规则集内容")
                    .font(.headline)
                Text(tag)
                    .monospaced()
                    .foregroundStyle(.secondary)
                if ruleCount > 0 {
                    Text("\(ruleCount) 条规则")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("关闭") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在读取...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(content)
                        .monospaced()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if isTruncated {
                    Text("⚠️ 文件过大，仅显示前 \(Self.maxDisplayLines) 行")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .frame(width: 700, height: 500)
        .task { await loadContent() }
    }

    private func loadContent() async {
        isLoading = true
        defer { isLoading = false }

        // Determine the local file path
        let filePath: String
        if type == "local" {
            filePath = ruleSet["path"]?.stringValue ?? ""
        } else {
            // Remote rule sets are cached in rules/ directory
            let ext = format == "binary" ? "srs" : "json"
            filePath = rulesDir.appendingPathComponent("\(tag).\(ext)").path
        }

        guard FileManager.default.fileExists(atPath: filePath) else {
            error = "本地缓存文件不存在\n\(filePath)\n\n请先点击「全部更新」下载规则集"
            return
        }

        if format == "binary" {
            // Use sing-box rule-set decompile to convert .srs to JSON
            await decompileBinary(path: filePath)
        } else {
            // Source format: read JSON directly
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
                let json = try prettyPrintJSON(data)
                content = json
                countRules(data: data)
            } catch {
                self.error = "读取失败: \(error.localizedDescription)"
            }
        }
    }

    private func decompileBinary(path: String) async {
        let tmpOutput = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-decompiled.json")
        defer { try? FileManager.default.removeItem(at: tmpOutput) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")
        proc.arguments = ["rule-set", "decompile", path, "-o", tmpOutput.path]
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "未知错误"
                error = "反编译失败: \(errMsg)"
                return
            }

            let data = try Data(contentsOf: tmpOutput)
            content = try prettyPrintJSON(data)
            countRules(data: data)
        } catch {
            self.error = "反编译失败: \(error.localizedDescription)"
        }
    }

    private func prettyPrintJSON(_ data: Data) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        guard let full = String(data: pretty, encoding: .utf8) else { return "" }
        let lines = full.components(separatedBy: "\n")
        if lines.count > Self.maxDisplayLines {
            isTruncated = true
            return lines.prefix(Self.maxDisplayLines).joined(separator: "\n")
        }
        return full
    }

    private func countRules(data: Data) {
        // Count rules from JSON structure: {"rules": [{...}, ...]} or {"version":1,"rules":[...]}
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rules = obj["rules"] as? [[String: Any]] {
            // Each rule object can contain multiple domain/domain_suffix/ip_cidr entries
            var count = 0
            for rule in rules {
                for (_, value) in rule {
                    if let arr = value as? [String] {
                        count += arr.count
                    }
                }
            }
            ruleCount = count > 0 ? count : rules.count
        }
    }
}

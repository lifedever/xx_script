import SwiftUI

struct RegionGroupsView: View {
    @Environment(AppState.self) private var appState
    @State private var patterns: [String: GroupPattern] = [:]
    @State private var orderedKeys: [String] = []
    @State private var editingKey: String?
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("地区分组")
                    .font(.title.bold())
                Spacer()
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if orderedKeys.isEmpty {
                emptyState
            } else {
                // Table header
                HStack(spacing: 0) {
                    Text("#").frame(width: 30, alignment: .leading)
                    Text("名称").frame(width: 140, alignment: .leading)
                    Text("类型").frame(width: 80, alignment: .leading)
                    Text("匹配模式").frame(width: 80, alignment: .leading)
                    Text("匹配规则").frame(minWidth: 160, alignment: .leading)
                    Spacer()
                    Text("操作").frame(width: 120, alignment: .center)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(orderedKeys.enumerated()), id: \.element) { index, key in
                            if let pattern = patterns[key] {
                                regionGroupTableRow(index: index, key: key, pattern: pattern)
                            }
                        }
                    }
                }

                Divider()

                bottomBar
            }
        }
        .onAppear { loadPatterns() }
        .sheet(isPresented: $showAddSheet) {
            RegionGroupEditSheet(mode: .add) { name, pattern in
                patterns[name] = pattern
                orderedKeys.append(name)
                savePatterns()
            }
            .environment(appState)
        }
        .sheet(item: $editingKey) { key in
            if let pattern = patterns[key] {
                RegionGroupEditSheet(mode: .edit(name: key, pattern: pattern)) { newName, newPattern in
                    if newName != key {
                        patterns.removeValue(forKey: key)
                        if let idx = orderedKeys.firstIndex(of: key) { orderedKeys[idx] = newName }
                    }
                    patterns[newName] = newPattern
                    savePatterns()
                }
                .environment(appState)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "globe").font(.largeTitle).foregroundStyle(.secondary)
                Text("暂无地区分组").font(.headline)
                Text("点击右上角 + 添加").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("恢复默认分组") { resetToDefault() }
                    .controlSize(.small).buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(verbatim: "\(orderedKeys.count) 个分组")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("恢复默认分组") { resetToDefault() }
                .controlSize(.small).buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func regionGroupTableRow(index: Int, key: String, pattern: GroupPattern) -> some View {
        let groupType = appState.configEngine.config.outbounds.first(where: { $0.tag == key }).map { ob -> String in
            switch ob { case .urltest: return "urltest"; default: return "selector" }
        } ?? "selector"

        return HStack(spacing: 0) {
            Text(verbatim: "\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            Text(key)
                .font(.body)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            Text(groupType)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(groupType == "urltest" ? Color.orange.opacity(0.12) : Color.blue.opacity(0.12))
                .foregroundStyle(groupType == "urltest" ? Color.orange : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 80, alignment: .leading)

            Text(pattern.mode == "regex" ? "正则" : "关键词")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(pattern.mode == "regex" ? Color.purple.opacity(0.12) : Color.green.opacity(0.12))
                .foregroundStyle(pattern.mode == "regex" ? .purple : .green)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 80, alignment: .leading)

            Text(pattern.patterns.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 160, alignment: .leading)

            Spacer()

            HStack(spacing: 4) {
                // Move buttons
                Button { moveUp(index) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)

                Button { moveDown(index) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == orderedKeys.count - 1)

                Button("编辑") { editingKey = key }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("删除") { deleteGroup(key) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            }
            .frame(width: 180, alignment: .center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(index % 2 == 0 ? Color.clear : Color.gray.opacity(0.06))
    }

    private func moveUp(_ index: Int) {
        guard index > 0 else { return }
        orderedKeys.swapAt(index, index - 1)
        savePatterns()
    }

    private func moveDown(_ index: Int) {
        guard index < orderedKeys.count - 1 else { return }
        orderedKeys.swapAt(index, index + 1)
        savePatterns()
    }

    private func loadPatterns() {
        patterns = appState.configEngine.loadGroupPatterns()
        orderedKeys = appState.configEngine.loadOrderedGroupKeys()
    }

    private func savePatterns() {
        appState.configEngine.saveGroupPatterns(patterns)
        appState.configEngine.saveGroupOrder(orderedKeys)
        try? appState.subscriptionService.regroupExistingNodes()
    }

    private func deleteGroup(_ key: String) {
        patterns.removeValue(forKey: key)
        orderedKeys.removeAll { $0 == key }
        savePatterns()
    }

    private func resetToDefault() {
        patterns = AutoGrouper().defaultPatterns()
        orderedKeys = patterns.keys.sorted()
        savePatterns()
    }
}


struct KeywordTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.1))
            .foregroundStyle(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// Make String conform to Identifiable for sheet(item:)
extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Edit Sheet

enum RegionGroupEditMode {
    case add
    case edit(name: String, pattern: GroupPattern)
}

struct RegionGroupEditSheet: View {
    @Environment(AppState.self) private var appState
    let mode: RegionGroupEditMode
    let onSave: (String, GroupPattern) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var groupType = "selector"
    @State private var matchMode = "keyword"
    @State private var patternsText = ""
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var allNodes: [String] {
        appState.configEngine.proxies.values.flatMap { $0.map(\.tag) }
    }

    private var matchedNodes: [String] {
        let patternList = patternsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !patternList.isEmpty else { return [] }
        return allNodes.filter { tag in
            let lower = tag.lowercased()
            if matchMode == "regex" {
                return patternList.contains { regex in
                    tag.range(of: regex, options: .regularExpression) != nil
                }
            } else {
                return patternList.contains { lower.contains($0) }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "编辑分组" : "添加分组").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding()

            Divider()

            Form {
                TextField("分组名称（如 🇭🇰香港）", text: $name)
                    .textFieldStyle(.roundedBorder)

                Picker("类型", selection: $groupType) {
                    Text("手动选择 (selector)").tag("selector")
                    Text("自动最优 (urltest)").tag("urltest")
                }

                Section("节点来源") {
                    Picker("匹配模式", selection: $matchMode) {
                        Text("关键词").tag("keyword")
                        Text("正则表达式").tag("regex")
                    }
                    .pickerStyle(.segmented)

                    TextField(
                        matchMode == "keyword" ? "香港, hk, hong kong" : "(?i)hk|hong.?kong|香港",
                        text: $patternsText
                    )
                    .textFieldStyle(.roundedBorder)

                    if matchMode == "keyword" {
                        Text("节点名称包含任一关键词即匹配（不区分大小写）")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text("节点名称匹配任一正则表达式即匹配")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }

                // Node preview
                let matched = matchedNodes
                if !matched.isEmpty {
                    Section("匹配预览: \(matched.count) 个节点") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(matched, id: \.self) { node in
                                    Text(node)
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }

                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear {
            if case .edit(let n, let p) = mode {
                name = n; matchMode = p.mode
                patternsText = p.patterns.joined(separator: ", ")
                // Read current group type from config
                if let ob = appState.configEngine.config.outbounds.first(where: { $0.tag == n }) {
                    switch ob {
                    case .urltest: groupType = "urltest"
                    default: groupType = "selector"
                    }
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { errorMessage = "请输入分组名称"; return }
        let patternList = patternsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !patternList.isEmpty else { errorMessage = "请输入至少一个匹配规则"; return }

        // Update group type in config if changed
        if let idx = appState.configEngine.config.outbounds.firstIndex(where: { $0.tag == trimmedName }) {
            let existing = appState.configEngine.config.outbounds[idx]
            if groupType == "urltest" {
                if case .selector(let s) = existing {
                    appState.configEngine.config.outbounds[idx] = .urltest(URLTestOutbound(tag: s.tag, outbounds: s.outbounds))
                }
            } else {
                if case .urltest(let u) = existing {
                    appState.configEngine.config.outbounds[idx] = .selector(SelectorOutbound(tag: u.tag, outbounds: u.outbounds))
                }
            }
        }

        dismiss()
        onSave(trimmedName, GroupPattern(mode: matchMode, patterns: patternList))
    }
}

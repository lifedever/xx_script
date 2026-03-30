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
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(orderedKeys, id: \.self) { key in
                            if let pattern = patterns[key] {
                                RegionGroupCard(
                                    name: key, pattern: pattern,
                                    onEdit: { editingKey = key },
                                    onDelete: { deleteGroup(key) }
                                )
                            }
                        }
                    }
                    .padding()
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

    private func loadPatterns() {
        patterns = appState.configEngine.loadGroupPatterns()
        orderedKeys = patterns.keys.sorted()
    }

    private func savePatterns() {
        appState.configEngine.saveGroupPatterns(patterns)
        // Re-group existing nodes immediately
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

// MARK: - Card

struct RegionGroupCard: View {
    let name: String
    let pattern: GroupPattern
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            keywordTags
            actionRow
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var headerRow: some View {
        HStack {
            Text(name).font(.headline)
            Spacer()
            modeBadge
        }
    }

    private var modeBadge: some View {
        let isRegex = pattern.mode == "regex"
        return Text(isRegex ? "正则" : "关键词")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isRegex ? Color.purple.opacity(0.12) : Color.blue.opacity(0.12))
            .foregroundStyle(isRegex ? .purple : .blue)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var keywordTags: some View {
        FlowLayout(spacing: 4) {
            ForEach(pattern.patterns, id: \.self) { keyword in
                KeywordTag(text: keyword)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Spacer()
            Button("编辑", action: onEdit).controlSize(.small).buttonStyle(.bordered)
            Button("删除", action: onDelete).controlSize(.small).buttonStyle(.bordered).tint(.red)
        }
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
    let mode: RegionGroupEditMode
    let onSave: (String, GroupPattern) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var matchMode = "keyword"
    @State private var patternsText = ""
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
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

                Picker("匹配模式", selection: $matchMode) {
                    Text("关键词").tag("keyword")
                    Text("正则表达式").tag("regex")
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text(matchMode == "keyword" ? "关键词（逗号分隔）" : "正则表达式（逗号分隔）")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(
                        matchMode == "keyword" ? "香港, hk, hong kong" : "(?i)hk|hong.?kong|香港",
                        text: $patternsText
                    )
                    .textFieldStyle(.roundedBorder)
                }

                if matchMode == "keyword" {
                    Text("节点名称包含任一关键词即匹配（不区分大小写）")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text("节点名称匹配任一正则表达式即匹配")
                        .font(.caption).foregroundStyle(.tertiary)
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
        .frame(width: 420)
        .onAppear {
            if case .edit(let n, let p) = mode {
                name = n; matchMode = p.mode
                patternsText = p.patterns.joined(separator: ", ")
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
        dismiss()
        onSave(trimmedName, GroupPattern(mode: matchMode, patterns: patternList))
    }
}

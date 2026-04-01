import SwiftUI

struct ProxyChainView: View {
    @Environment(AppState.self) private var appState
    @State private var detourTarget: String?
    @State private var showDetourPicker = false

    private struct ChainedSection: Identifiable {
        let sub: String
        let nodes: [(tag: String, detour: String)]
        var id: String { sub }
    }

    private var chainedNodes: [ChainedSection] {
        var result: [ChainedSection] = []
        for (sub, nodes) in appState.configEngine.proxies.sorted(by: { $0.key < $1.key }) {
            var chained: [(String, String)] = []
            for node in nodes {
                if let d = node.detour {
                    chained.append((node.tag, d))
                }
            }
            if !chained.isEmpty {
                result.append(ChainedSection(sub: sub, nodes: chained))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("链式代理")
                    .font(.title2)
                    .bold()
                let count = chainedNodes.flatMap(\.nodes).count
                Text("\(count) 条链路")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("客户端 → 前置代理 → 目标节点 → 目的地")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button {
                    detourTarget = nil
                    showDetourPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("新增链路")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()

            Divider()

            if chainedNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "link")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text("暂无链式代理")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("为节点设置前置代理，流量会先经过前置代理再到目标节点")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Table header
                HStack(spacing: 0) {
                    Text("节点")
                        .frame(width: 250, alignment: .leading)
                    Text("前置代理")
                        .frame(width: 250, alignment: .leading)
                    Spacer()
                    Text("操作")
                        .frame(width: 150, alignment: .center)
                }
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chainedNodes, id: \.sub) { section in
                            Text("📦 \(section.sub)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            ForEach(Array(section.nodes.enumerated()), id: \.element.tag) { idx, item in
                                HStack(spacing: 0) {
                                    Text(item.tag)
                                        .lineLimit(1)
                                        .frame(width: 250, alignment: .leading)

                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.right")
                                            .foregroundStyle(.orange)
                                        Text(item.detour)
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 250, alignment: .leading)

                                    Spacer()

                                    HStack(spacing: 6) {
                                        Button("修改") {
                                            detourTarget = item.tag
                                            showDetourPicker = true
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button("删除") {
                                            setDetour(nodeTag: item.tag, detour: nil)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .tint(.red)
                                    }
                                    .frame(width: 150, alignment: .center)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .background(idx % 2 == 0 ? Color.clear : Color.gray.opacity(0.04))
                            }
                        }
                    }
                    .padding(.bottom)
                }
            }
        }
        .sheet(isPresented: $showDetourPicker) {
            ProxyChainEditSheet(
                nodeTag: detourTarget,
                appState: appState,
                onSave: { nodeTag, detour in
                    setDetour(nodeTag: nodeTag, detour: detour)
                    showDetourPicker = false
                    detourTarget = nil
                },
                onCancel: {
                    showDetourPicker = false
                    detourTarget = nil
                }
            )
        }
    }

    private func setDetour(nodeTag: String, detour: String?) {
        for (subName, nodes) in appState.configEngine.proxies {
            if let idx = nodes.firstIndex(where: { $0.tag == nodeTag }) {
                var updated = nodes
                updated[idx].detour = detour
                try? appState.configEngine.saveProxies(name: subName, nodes: updated)
                try? appState.configEngine.save(restartRequired: true)
                return
            }
        }
    }
}

// MARK: - Edit Sheet

private struct ProxyChainEditSheet: View {
    let nodeTag: String?  // nil = adding new, non-nil = editing
    let appState: AppState
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var selectedNode: String?
    @State private var selectedDetour: String?
    @State private var searchText = ""

    private var isEditing: Bool { nodeTag != nil }

    private var availableNodes: [(section: String, tags: [String])] {
        appState.configEngine.proxies.sorted(by: { $0.key < $1.key }).compactMap { (sub, nodes) in
            let tags = nodes.filter { $0.isProxyNode }.map(\.tag)
            return tags.isEmpty ? nil : ("📦 \(sub)", tags)
        }
    }

    private var availableDetours: [(section: String, tags: [String])] {
        var sections: [(String, [String])] = []

        let groups = appState.configEngine.config.outbounds.compactMap { o -> String? in
            switch o {
            case .selector, .urltest: return o.tag
            default: return nil
            }
        }
        if !groups.isEmpty { sections.append(("策略组", groups)) }

        for (sub, nodes) in appState.configEngine.proxies.sorted(by: { $0.key < $1.key }) {
            let tags = nodes.compactMap { $0.tag != selectedNode ? $0.tag : nil }
            if !tags.isEmpty { sections.append(("📦 \(sub)", tags)) }
        }

        sections.append(("其他", ["DIRECT"]))
        return sections
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "修改前置代理" : "新增链路").font(.headline)
                    Text("选择目标节点和它要经过的前置代理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { onCancel() }.keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            HStack(alignment: .top, spacing: 0) {
                // Left: node selection (only when adding)
                if !isEditing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("① 目标节点").font(.subheadline).bold()
                            .padding(.horizontal)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(availableNodes, id: \.section) { section in
                                    Text(section.section)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal)
                                        .padding(.top, 6)
                                    ForEach(section.tags, id: \.self) { tag in
                                        Button { selectedNode = tag } label: {
                                            HStack {
                                                Image(systemName: selectedNode == tag ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(selectedNode == tag ? Color.blue : Color.gray.opacity(0.3))
                                                Text(tag).lineLimit(1)
                                                Spacer()
                                            }
                                            .padding(.horizontal)
                                            .padding(.vertical, 3)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .background(selectedNode == tag ? Color.accentColor.opacity(0.08) : Color.clear)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 250)

                    Divider()
                }

                // Right: detour selection
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(isEditing ? "前置代理" : "② 前置代理").font(.subheadline).bold()
                        if let node = selectedNode ?? nodeTag {
                            Text(node).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal)

                    TextField("搜索...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredDetours, id: \.section) { section in
                                Text(section.section)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                                    .padding(.top, 6)
                                ForEach(section.tags, id: \.self) { tag in
                                    Button { selectedDetour = tag } label: {
                                        HStack {
                                            Image(systemName: selectedDetour == tag ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedDetour == tag ? Color.blue : Color.gray.opacity(0.3))
                                            Text(tag).lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 3)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .background(selectedDetour == tag ? Color.accentColor.opacity(0.08) : Color.clear)
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 250)
            }

            Divider()

            HStack {
                Spacer()
                Button("确定") {
                    guard let node = selectedNode ?? nodeTag,
                          let detour = selectedDetour else { return }
                    onSave(node, detour)
                }
                .buttonStyle(.borderedProminent)
                .disabled((selectedNode ?? nodeTag) == nil || selectedDetour == nil)
            }
            .padding()
        }
        .frame(width: isEditing ? 400 : 600, height: 500)
        .onAppear {
            selectedNode = nodeTag
            if let nodeTag {
                // Load current detour when editing
                for (_, nodes) in appState.configEngine.proxies {
                    if let node = nodes.first(where: { $0.tag == nodeTag }) {
                        selectedDetour = node.detour
                        break
                    }
                }
            }
        }
    }

    private var filteredDetours: [(section: String, tags: [String])] {
        availableDetours.compactMap { entry in
            let tags = searchText.isEmpty ? entry.tags
                : entry.tags.filter { $0.localizedCaseInsensitiveContains(searchText) }
            return tags.isEmpty ? nil : (entry.section, tags)
        }
    }
}

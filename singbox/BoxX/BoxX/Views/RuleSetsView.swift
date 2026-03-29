import SwiftUI

struct RuleSetsView: View {
    @Environment(AppState.self) private var appState

    @State private var ruleSetUpdateStatus: [String: RuleSetUpdateStatus] = [:]

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
                    let ruleSets = appState.configEngine.config.route.ruleSet ?? []
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
                                .frame(width: 120, alignment: .leading)
                            Text("")
                                .frame(width: 30)
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

            // Outbound column (inline picker)
            Group {
                let currentOutbound = outboundForRuleSet(tag: tag)
                if currentOutbound != nil {
                    Picker("", selection: Binding(
                        get: { currentOutbound ?? "Proxy" },
                        set: { newValue in
                            changeOutbound(forRuleSetTag: tag, to: newValue)
                        }
                    )) {
                        ForEach(availableOutbounds, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                } else {
                    Text("未关联")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 140, alignment: .leading)

            // Refresh / status column
            Group {
                if let status = ruleSetUpdateStatus[tag] {
                    switch status {
                    case .updating:
                        ProgressView().controlSize(.small)
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    case .idle:
                        ruleSetRefreshButton(tag: tag, url: url, isRemote: isRemote)
                    }
                } else {
                    ruleSetRefreshButton(tag: tag, url: url, isRemote: isRemote)
                }
            }
            .frame(width: 30)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(index % 2 == 0 ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial.opacity(0.5)))
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
            EmptyView()
        }
    }

    // MARK: - Outbound Helpers

    private var availableOutbounds: [String] {
        appState.configEngine.config.outbounds.compactMap { outbound in
            switch outbound {
            case .selector(let s): return s.tag
            case .direct(let d): return d.tag
            default: return nil
            }
        }
    }

    private func outboundForRuleSet(tag: String) -> String? {
        let rules = appState.configEngine.config.route.rules ?? []
        for rule in rules {
            guard let ruleSetRefs = rule["rule_set"]?.arrayValue else { continue }
            let tags = ruleSetRefs.compactMap { $0.stringValue }
            if tags.contains(tag) {
                return rule["outbound"]?.stringValue
            }
        }
        return nil
    }

    private func changeOutbound(forRuleSetTag tag: String, to newOutbound: String) {
        var rules = appState.configEngine.config.route.rules ?? []
        for i in rules.indices {
            guard let ruleSetRefs = rules[i]["rule_set"]?.arrayValue else { continue }
            let tags = ruleSetRefs.compactMap { $0.stringValue }
            if tags.contains(tag) {
                if case .object(var dict) = rules[i] {
                    dict["outbound"] = .string(newOutbound)
                    rules[i] = .object(dict)
                }
                break
            }
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

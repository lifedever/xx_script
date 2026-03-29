import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @State private var proxyGroups: [ProxyGroup] = []
    @State private var isUpdatingSubscriptions = false
    @State private var currentMode: String = "rule"

    // MARK: - Group Classification (shared with ProxiesView)

    private struct ClassifiedGroups {
        var top: [ProxyGroup] = []
        var services: [ProxyGroup] = []
        var regions: [ProxyGroup] = []
        var subscriptions: [ProxyGroup] = []
    }

    private var classified: ClassifiedGroups {
        classifyGroups(proxyGroups.filter { $0.type == "Selector" })
    }

    private func classifyGroups(_ groups: [ProxyGroup]) -> ClassifiedGroups {
        let serviceNames: Set<String> = [
            "OpenAI", "Google", "YouTube", "Netflix",
            "Disney", "TikTok", "Microsoft", "Notion",
            "Apple", "Telegram", "Spotify", "Twitter",
            "GitHub", "Steam", "Twitch", "Claude",
            "Gemini", "ChatGPT"
        ]
        let regionPrefixes = ["🇭🇰", "🇨🇳", "🇯🇵", "🇰🇷", "🇸🇬", "🇺🇸", "🇬🇧", "🇩🇪", "🇫🇷", "🇦🇺", "🇨🇦", "🇹🇼", "🌍"]
        let regionNames = ["香港", "日本", "韩国", "新加坡", "美国", "英国", "德国", "法国", "澳大利亚", "加拿大", "台湾"]

        var result = ClassifiedGroups()
        var classifiedIDs = Set<String>()

        for group in groups {
            if group.name.hasPrefix("📦") {
                result.subscriptions.append(group)
                classifiedIDs.insert(group.id)
            } else if regionPrefixes.contains(where: { group.name.hasPrefix($0) })
                        || regionNames.contains(where: { group.name.contains($0) }) {
                result.regions.append(group)
                classifiedIDs.insert(group.id)
            } else if serviceNames.contains(where: { group.name.contains($0) }) {
                result.services.append(group)
                classifiedIDs.insert(group.id)
            }
        }

        for group in groups where !classifiedIDs.contains(group.id) {
            result.top.append(group)
        }

        return result
    }

    // MARK: - Body

    var body: some View {
        Group {
            // ── Status header ──
            statusHeader

            Divider()

            // ── Outbound mode submenu ──
            modeMenu

            Divider()

            // ── Top-level groups (Proxy, etc.) ──
            if !classified.top.isEmpty {
                ForEach(classified.top) { group in
                    groupSubmenu(group)
                }
                Divider()
            }

            // ── Services section ──
            if !classified.services.isEmpty {
                Text(String(localized: "proxies.section.services"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(classified.services) { group in
                    groupSubmenu(group)
                }
                Divider()
            }

            // ── Regions section ──
            if !classified.regions.isEmpty {
                Text(String(localized: "proxies.section.regions"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(classified.regions) { group in
                    groupSubmenu(group)
                }
                Divider()
            }

            // ── Subscriptions section ──
            if !classified.subscriptions.isEmpty {
                Text(String(localized: "proxies.section.subscriptions"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(classified.subscriptions) { group in
                    groupSubmenu(group)
                }
                Divider()
            }

            // ── Bottom actions ──
            bottomActions
        }
        .task { await syncStatus() }
    }

    // MARK: - Status Header

    @ViewBuilder
    private var statusHeader: some View {
        if appState.isRunning {
            Label {
                HStack {
                    Text("BoxX")
                    Spacer()
                    Text(String(localized: "menu.status.running"))
                        .foregroundStyle(.green)
                }
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
            }
        } else {
            Label {
                HStack {
                    Text("BoxX")
                    Spacer()
                    Text(String(localized: "menu.status.stopped"))
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
            }
        }
    }

    // MARK: - Mode Menu

    private var modeMenu: some View {
        Menu {
            ForEach(["rule", "global", "direct"], id: \.self) { mode in
                Button {
                    Task { try? await appState.api.setMode(mode); await syncStatus() }
                } label: {
                    if currentMode == mode {
                        Label(modeLabel(mode), systemImage: "checkmark")
                    } else {
                        Text(modeLabel(mode))
                    }
                }
            }
        } label: {
            HStack {
                Text(String(localized: "menu.outbound_mode"))
                Spacer()
                Text(modeLabel(currentMode))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Group Submenu

    @ViewBuilder
    private func groupSubmenu(_ group: ProxyGroup) -> some View {
        Menu {
            ForEach(group.displayAll, id: \.self) { node in
                Button {
                    Task { await selectNode(group: group.name, node: node) }
                } label: {
                    if group.now == node {
                        Label(node, systemImage: "checkmark")
                    } else {
                        Text(node)
                    }
                }
            }
        } label: {
            HStack {
                Text(group.name)
                Spacer()
                Text(group.now ?? "–")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Bottom Actions

    @ViewBuilder
    private var bottomActions: some View {
        // Update subscriptions
        Button(isUpdatingSubscriptions
               ? String(localized: "menu.updating")
               : String(localized: "menu.update_subscriptions")) {
            guard !isUpdatingSubscriptions else { return }
            isUpdatingSubscriptions = true
            Task {
                let subs = SubscriptionsView.loadSubscriptions()
                let subService = appState.subscriptionService
                for sub in subs {
                    guard let url = URL(string: sub.url) else { continue }
                    _ = try? await subService.updateSubscription(name: sub.name, url: url)
                }
                isUpdatingSubscriptions = false
                await syncStatus()
            }
        }
        .disabled(isUpdatingSubscriptions)

        // Open config directory
        Button(String(localized: "menu.open_config_dir")) {
            NSWorkspace.shared.open(appState.configEngine.baseDir)
        }

        // Show main window
        Button(String(localized: "menu.show_main_window")) {
            openWindow(id: "main")
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.activate() }
        }

        Divider()

        // Quit
        Button(String(localized: "menu.quit")) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Helpers

    private func modeLabel(_ mode: String) -> String {
        switch mode {
        case "rule": return String(localized: "menu.mode.rule")
        case "global": return String(localized: "menu.mode.global")
        case "direct": return String(localized: "menu.mode.direct")
        default: return mode
        }
    }

    private func selectNode(group: String, node: String) async {
        // Dual-write: update via Clash API and persist to ConfigEngine
        try? await appState.api.selectProxy(group: group, name: node)

        // Persist selection to ConfigEngine config
        if let idx = appState.configEngine.config.outbounds.firstIndex(where: {
            if case .selector(let s) = $0, s.tag == group { return true }
            return false
        }) {
            if case .selector(var selector) = appState.configEngine.config.outbounds[idx] {
                selector.`default` = node
                appState.configEngine.config.outbounds[idx] = .selector(selector)
                try? appState.configEngine.save()
            }
        }

        await refreshProxyGroups()
    }

    private func syncStatus() async {
        let status = await appState.xpcClient.getStatus()
        appState.isRunning = status.running
        if let config = try? await appState.api.getConfig() {
            currentMode = config.mode ?? "rule"
        }
        await refreshProxyGroups()
    }

    private func refreshProxyGroups() async {
        proxyGroups = (try? await appState.api.getProxies()) ?? []
    }
}

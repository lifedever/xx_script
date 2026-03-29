import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    let singBoxManager: SingBoxManager
    let configGenerator: ConfigGenerator
    let api: ClashAPI

    @State private var proxyGroups: [ProxyGroup] = []
    @State private var isUpdatingSubscriptions = false
    @State private var currentMode: String = "rule"

    var body: some View {
        Group {
            // Status
            if appState.isRunning {
                Label(String(localized: "menu.status.running"), systemImage: "circle.fill")
                    .foregroundStyle(Color.green)
            } else {
                Label(String(localized: "menu.status.stopped"), systemImage: "circle")
                    .foregroundStyle(Color.secondary)
            }

            Divider()

            // Start / Stop
            if appState.isRunning {
                Button(String(localized: "menu.stop")) {
                    Task {
                        do { try await singBoxManager.stop() }
                        catch { appState.showAlert(error.localizedDescription) }
                        await syncStatus()
                    }
                }
            } else {
                Button(String(localized: "menu.start")) {
                    Task {
                        do { try await singBoxManager.start(configPath: configGenerator.configPath) }
                        catch { appState.showAlert(error.localizedDescription) }
                        await syncStatus()
                    }
                }
            }

            // Mode submenu
            Menu(String(localized: "menu.proxy_mode")) {
                ForEach(["rule", "global", "direct"], id: \.self) { mode in
                    Button {
                        Task { try? await api.setMode(mode); await syncStatus() }
                    } label: {
                        if currentMode == mode {
                            Label(modeLabel(mode), systemImage: "checkmark")
                        } else {
                            Text(modeLabel(mode))
                        }
                    }
                }
            }

            Divider()

            // Proxy groups — categorized
            if proxyGroups.isEmpty {
                Text(String(localized: "menu.no_proxy_groups"))
                    .foregroundStyle(.secondary)
            } else {
                let selectors = proxyGroups.filter { $0.type == "Selector" }
                let regionPrefixes = ["🇭🇰", "🇨🇳", "🇯🇵", "🇰🇷", "🇸🇬", "🇺🇸", "🌍"]
                let regions = selectors.filter { g in regionPrefixes.contains(where: { g.name.hasPrefix($0) }) }
                let subs = selectors.filter { $0.name.hasPrefix("📦") }
                let regionIDs = Set(regions.map(\.id))
                let subIDs = Set(subs.map(\.id))
                let builtinNames: Set<String> = ["Proxy", "🐟漏网之鱼"]
                let builtins = selectors.filter { builtinNames.contains($0.name) }
                let services = selectors.filter { !regionIDs.contains($0.id) && !subIDs.contains($0.id) && !builtinNames.contains($0.name) }

                // Proxy & catch-all at the top
                if !builtins.isEmpty {
                    ForEach(builtins) { group in
                        Menu(group.name) {
                            ForEach(group.displayAll, id: \.self) { node in
                                Button {
                                    Task {
                                        try? await api.selectProxy(group: group.name, name: node)
                                        await refreshProxyGroups()
                                    }
                                } label: {
                                    if group.now == node { Label(node, systemImage: "checkmark") }
                                    else { Text(node) }
                                }
                            }
                        }
                    }
                    Divider()
                }
                if !services.isEmpty { menuSection(String(localized: "proxies.section.services"), groups: services) }
                if !regions.isEmpty { menuSection(String(localized: "proxies.section.regions"), groups: regions) }
                if !subs.isEmpty { menuSection(String(localized: "proxies.section.subscriptions"), groups: subs) }
            }

            Divider()

            // Dashboard & Settings
            Button(String(localized: "menu.open_dashboard")) {
                openWindow(id: "main")
                NSApp.setActivationPolicy(.regular)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.activate() }
            }

            Button(String(localized: "menu.settings")) {
                openWindow(id: "settings")
                NSApp.setActivationPolicy(.regular)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.activate() }
            }

            Divider()

            // Utilities (bottom)
            Button(isUpdatingSubscriptions ? String(localized: "menu.updating") : String(localized: "menu.update_subscriptions")) {
                guard !isUpdatingSubscriptions else { return }
                isUpdatingSubscriptions = true
                Task {
                    for await line in configGenerator.generate() { print("[generate] \(line)") }
                    isUpdatingSubscriptions = false
                    await syncStatus()
                }
            }
            .disabled(isUpdatingSubscriptions)

            Button(String(localized: "menu.copy_proxy_env")) {
                let env = "export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(env, forType: .string)
            }

            Divider()

            Button(String(localized: "menu.quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .task { await syncStatus() }
    }

    @ViewBuilder
    private func menuSection(_ title: String, groups: [ProxyGroup]) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
        ForEach(groups) { group in
            Menu(group.name) {
                ForEach(group.displayAll, id: \.self) { node in
                    Button {
                        Task {
                            try? await api.selectProxy(group: group.name, name: node)
                            await refreshProxyGroups()
                        }
                    } label: {
                        if group.now == node {
                            Label(node, systemImage: "checkmark")
                        } else { Text(node) }
                    }
                }
            }
        }
        Divider()
    }

    private func modeLabel(_ mode: String) -> String {
        switch mode {
        case "rule": return String(localized: "menu.mode.rule")
        case "global": return String(localized: "menu.mode.global")
        case "direct": return String(localized: "menu.mode.direct")
        default: return mode
        }
    }

    private func syncStatus() async {
        await singBoxManager.refreshStatus()
        appState.isRunning = singBoxManager.isRunning
        if let config = try? await api.getConfig() { currentMode = config.mode ?? "rule" }
        await refreshProxyGroups()
    }

    private func refreshProxyGroups() async {
        proxyGroups = (try? await api.getProxies()) ?? []
    }
}

import SwiftUI
import ServiceManagement

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
                if singBoxManager.isExternalProcess {
                    Label(String(localized: "menu.status.running.external"), systemImage: "circle.fill")
                        .foregroundStyle(Color.green)
                } else if appState.pid != 0 {
                    Label(String(format: String(localized: "menu.status.running.pid"), appState.pid), systemImage: "circle.fill")
                        .foregroundStyle(Color.green)
                } else {
                    Label(String(localized: "menu.status.running"), systemImage: "circle.fill")
                        .foregroundStyle(Color.green)
                }
            } else {
                Label(String(localized: "menu.status.stopped"), systemImage: "circle")
                    .foregroundStyle(Color.secondary)
            }

            // Helper not installed warning
            if !appState.isHelperInstalled {
                Label(String(localized: "menu.helper_not_installed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
            }

            Divider()

            // Start / Stop
            if appState.isRunning {
                Button(String(localized: "menu.stop")) {
                    Task {
                        do {
                            try await singBoxManager.stopAny()
                        } catch {
                            appState.showAlert(error.localizedDescription)
                        }
                        await syncStatus()
                    }
                }
            } else {
                if appState.isHelperInstalled {
                    Button(String(localized: "menu.start")) {
                        Task {
                            do {
                                try await singBoxManager.start(configPath: configGenerator.configPath)
                            } catch {
                                appState.showAlert(error.localizedDescription)
                            }
                            await syncStatus()
                        }
                    }
                } else {
                    Button(String(localized: "menu.start")) {
                        showNSAlert(
                            title: String(localized: "menu.start"),
                            message: String(localized: "menu.start_no_helper_hint"),
                            style: .informational
                        )
                    }
                }
            }

            // Update Subscriptions
            Button(isUpdatingSubscriptions ? String(localized: "menu.updating") : String(localized: "menu.update_subscriptions")) {
                guard !isUpdatingSubscriptions else { return }
                isUpdatingSubscriptions = true
                Task {
                    for await line in configGenerator.generate() {
                        print("[ConfigGenerator] \(line)")
                    }
                    isUpdatingSubscriptions = false
                    await syncStatus()
                }
            }
            .disabled(isUpdatingSubscriptions)

            // Copy Proxy Env
            Button(String(localized: "menu.copy_proxy_env")) {
                let envString = "export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(envString, forType: .string)
                showNSAlert(
                    title: String(localized: "menu.copy_proxy_env"),
                    message: String(localized: "menu.proxy_env_copied"),
                    style: .informational
                )
            }

            // Mode submenu
            Menu(String(localized: "menu.proxy_mode")) {
                Button {
                    Task { try? await api.setMode("rule"); await syncStatus() }
                } label: {
                    if currentMode == "rule" {
                        Label(String(localized: "menu.mode.rule"), systemImage: "checkmark")
                    } else {
                        Text(String(localized: "menu.mode.rule"))
                    }
                }
                Button {
                    Task { try? await api.setMode("global"); await syncStatus() }
                } label: {
                    if currentMode == "global" {
                        Label(String(localized: "menu.mode.global"), systemImage: "checkmark")
                    } else {
                        Text(String(localized: "menu.mode.global"))
                    }
                }
                Button {
                    Task { try? await api.setMode("direct"); await syncStatus() }
                } label: {
                    if currentMode == "direct" {
                        Label(String(localized: "menu.mode.direct"), systemImage: "checkmark")
                    } else {
                        Text(String(localized: "menu.mode.direct"))
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
                let rules = selectors.filter { !regionIDs.contains($0.id) && !subIDs.contains($0.id) }

                if !rules.isEmpty {
                    menuSection(String(localized: "proxies.section.services"), groups: rules)
                }
                if !regions.isEmpty {
                    menuSection(String(localized: "proxies.section.regions"), groups: regions)
                }
                if !subs.isEmpty {
                    menuSection(String(localized: "proxies.section.subscriptions"), groups: subs)
                }
            }

            Divider()

            // Install / Uninstall Helper
            if appState.isHelperInstalled {
                Button(String(localized: "menu.uninstall_helper")) {
                    uninstallHelper()
                }
            } else {
                Button(String(localized: "menu.install_helper")) {
                    installHelper()
                }
            }

            // Open Dashboard
            Button(String(localized: "menu.open_dashboard")) {
                openWindow(id: "main")
                NSApp.setActivationPolicy(.regular)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate()
                    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
                }
            }

            // Settings
            Button(String(localized: "menu.settings")) {
                openWindow(id: "settings")
                NSApp.setActivationPolicy(.regular)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate()
                    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
                }
            }

            Divider()

            // Quit
            Button(String(localized: "menu.quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .task {
            await syncStatus()
        }
    }

    @ViewBuilder
    private func menuSection(_ title: String, groups: [ProxyGroup]) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
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
                        } else {
                            Text(node)
                        }
                    }
                }
            }
        }
        Divider()
    }

    private func syncStatus() async {
        appState.isHelperInstalled = HelperManager.shared.isHelperInstalled
        await singBoxManager.refreshStatus()
        appState.isRunning = singBoxManager.isRunning
        appState.pid = singBoxManager.pid
        if let config = try? await api.getConfig() {
            currentMode = config.mode ?? "rule"
        }
        await refreshProxyGroups()
    }

    private func refreshProxyGroups() async {
        do {
            proxyGroups = try await api.getProxies()
        } catch {
            proxyGroups = []
        }
    }

    private func installHelper() {
        do {
            try HelperManager.shared.installHelper()
        } catch {
            // SMAppService may throw even when authorization prompt succeeds
            // Check actual status after a brief delay
        }
        // Always re-check actual status
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            appState.isHelperInstalled = HelperManager.shared.isHelperInstalled
            if appState.isHelperInstalled {
                showNSAlert(
                    title: String(localized: "settings.helper.installed"),
                    message: String(localized: "menu.helper_install_success"),
                    style: .informational
                )
            } else {
                showNSAlert(
                    title: String(localized: "error.title"),
                    message: String(localized: "menu.helper_install_failed"),
                    style: .warning
                )
            }
        }
    }

    private func uninstallHelper() {
        do {
            try HelperManager.shared.uninstallHelper()
        } catch {
            // ignore
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            appState.isHelperInstalled = HelperManager.shared.isHelperInstalled
            if !appState.isHelperInstalled {
                showNSAlert(
                    title: String(localized: "menu.helper_uninstalled"),
                    message: String(localized: "menu.helper_uninstall_success"),
                    style: .informational
                )
            }
        }
    }

    private func showNSAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: String(localized: "error.ok"))
        // Activate app so alert is visible
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        alert.runModal()
        // Go back to accessory if no window is open
        if NSApp.windows.filter({ $0.isVisible && $0.title != "" }).isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

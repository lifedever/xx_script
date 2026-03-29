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

            Divider()

            // Proxy group submenus (only Selector groups)
            if proxyGroups.isEmpty {
                Text(String(localized: "menu.no_proxy_groups"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(proxyGroups.filter { $0.type == "Selector" }) { group in
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
            }

            Divider()

            // Install Helper (only when not installed)
            if !appState.isHelperInstalled {
                Button(String(localized: "menu.install_helper")) {
                    installHelper()
                }
            }

            // Open Dashboard
            Button(String(localized: "menu.open_dashboard")) {
                openWindow(id: "main")
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }

            // Settings
            Button(String(localized: "menu.settings")) {
                // Must switch to regular mode first for Settings window to work
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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

    private func syncStatus() async {
        appState.isHelperInstalled = HelperManager.shared.isHelperInstalled
        await singBoxManager.refreshStatus()
        appState.isRunning = singBoxManager.isRunning
        appState.pid = singBoxManager.pid
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
            appState.isHelperInstalled = true
            showNSAlert(
                title: String(localized: "settings.helper.installed"),
                message: String(localized: "menu.helper_install_success"),
                style: .informational
            )
        } catch {
            showNSAlert(
                title: String(localized: "error.title"),
                message: error.localizedDescription,
                style: .critical
            )
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

import SwiftUI

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

            Divider()

            // Start / Stop
            if appState.isRunning {
                Button(String(localized: "menu.stop")) {
                    Task {
                        do {
                            try await singBoxManager.stop()
                        } catch {
                            appState.showAlert(error.localizedDescription)
                        }
                        await syncStatus()
                    }
                }
            } else {
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
                    // Refresh after update
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

            // Open Dashboard
            Button(String(localized: "menu.open_dashboard")) {
                openWindow(id: "main")
                NSApp.activate()
            }

            // Settings
            Button(String(localized: "menu.settings")) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate()
            }

            Divider()

            // Quit
            Button(String(localized: "menu.quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .task {
            // Refresh status first, THEN load proxy groups
            await syncStatus()
        }
    }

    /// Sync sing-box status + proxy groups in one shot
    private func syncStatus() async {
        await singBoxManager.refreshStatus()
        appState.isRunning = singBoxManager.isRunning
        appState.pid = singBoxManager.pid
        await refreshProxyGroups()
    }

    private func refreshProxyGroups() async {
        // Don't gate on appState.isRunning — just try the API directly
        // If API is reachable, we have groups. If not, empty.
        do {
            proxyGroups = try await api.getProxies()
        } catch {
            proxyGroups = []
        }
    }
}

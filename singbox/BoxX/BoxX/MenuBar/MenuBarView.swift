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
                } else {
                    Label(String(format: String(localized: "menu.status.running.pid"), appState.pid), systemImage: "circle.fill")
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
                            await singBoxManager.refreshStatus()
                            appState.isRunning = singBoxManager.isRunning
                            appState.pid = singBoxManager.pid
                        } catch {
                            appState.showAlert(error.localizedDescription)
                        }
                    }
                }
            } else {
                Button(String(localized: "menu.start")) {
                    Task {
                        do {
                            try await singBoxManager.start(configPath: configGenerator.configPath)
                            await singBoxManager.refreshStatus()
                            appState.isRunning = singBoxManager.isRunning
                            appState.pid = singBoxManager.pid
                        } catch {
                            appState.showAlert(error.localizedDescription)
                        }
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
                        let nodes = group.displayAll
                        ForEach(nodes, id: \.self) { node in
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
            await refreshProxyGroups()
        }
    }

    private func refreshProxyGroups() async {
        guard appState.isRunning else {
            proxyGroups = []
            return
        }
        do {
            proxyGroups = try await api.getProxies()
        } catch {
            // silently ignore when API is unreachable
        }
    }
}

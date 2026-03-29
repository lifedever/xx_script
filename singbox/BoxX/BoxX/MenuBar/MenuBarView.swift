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
                    Label("Running (external)", systemImage: "circle.fill")
                        .foregroundStyle(Color.green)
                } else {
                    Label("Running (PID: \(appState.pid))", systemImage: "circle.fill")
                        .foregroundStyle(Color.green)
                }
            } else {
                Label("Stopped", systemImage: "circle")
                    .foregroundStyle(Color.secondary)
            }

            Divider()

            // Start / Stop
            if appState.isRunning {
                Button("Stop sing-box") {
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
                Button("Start sing-box") {
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
            Button(isUpdatingSubscriptions ? "Updating…" : "Update Subscriptions") {
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
                Text("No proxy groups")
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
            Button("Open Dashboard") {
                openWindow(id: "main")
                NSApp.activate()
            }

            // Settings
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate()
            }

            Divider()

            // Quit
            Button("Quit BoxX") {
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

import SwiftUI

@main
struct BoxXApp: App {
    @State private var appState = AppState()
    @State private var singBoxManager = SingBoxManager.shared
    @State private var configGenerator = ConfigGenerator()
    private let api = ClashAPI()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                singBoxManager: singBoxManager,
                configGenerator: configGenerator,
                api: api
            )
            .environment(appState)
            .task {
                await singBoxManager.refreshStatus()
                appState.isRunning = singBoxManager.isRunning
                appState.pid = singBoxManager.pid
            }
        } label: {
            Image(systemName: appState.isRunning ? "network" : "network.slash")
        }

        Window("BoxX", id: "main") {
            MainView(
                api: api,
                singBoxManager: singBoxManager,
                configGenerator: configGenerator
            )
            .environment(appState)
        }
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
        }
    }
}

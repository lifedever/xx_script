import SwiftUI

@main
struct BoxXApp: App {
    @State private var appState = AppState()
    @State private var singBoxManager = SingBoxManager.shared
    @State private var configGenerator = ConfigGenerator()
    @State private var wakeObserver: WakeObserver?
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
                // Initial status refresh
                await singBoxManager.refreshStatus()
                appState.isRunning = singBoxManager.isRunning
                appState.pid = singBoxManager.pid

                // Setup WakeObserver
                let observer = WakeObserver(
                    singBoxManager: singBoxManager,
                    api: api,
                    configPath: configGenerator.configPath
                )
                wakeObserver = observer
                await observer.startObserving()
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
            .alert("Error", isPresented: Binding(
                get: { appState.showError },
                set: { appState.showError = $0 }
            )) {
                Button("OK", role: .cancel) { appState.showError = false }
            } message: {
                Text(appState.errorMessage ?? "An unknown error occurred.")
            }
        }
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
        }
    }
}

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
                // Setup WakeObserver (status refresh is handled by MenuBarView.syncStatus)
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
            .alert(String(localized: "error.title"), isPresented: Binding(
                get: { appState.showError },
                set: { appState.showError = $0 }
            )) {
                Button(String(localized: "error.ok"), role: .cancel) { appState.showError = false }
            } message: {
                Text(appState.errorMessage ?? "An unknown error occurred.")
            }
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "appmenu.about")) {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button(String(localized: "appmenu.quit")) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            CommandGroup(replacing: .windowList) {
                EmptyView()
            }
        }

        Settings {
            SettingsView()
        }
    }
}

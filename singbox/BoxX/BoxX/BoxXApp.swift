import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let appState = AppState.shared
            let manager = SingBoxManager.shared

            // Check status on launch
            await manager.refreshStatus()
            appState.isRunning = manager.isRunning
            appState.pid = manager.pid
            appState.isHelperInstalled = HelperManager.shared.isHelperInstalled
        }
    }
}

@main
struct BoxXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let appState = AppState.shared
    private let singBoxManager = SingBoxManager.shared
    private let configGenerator = ConfigGenerator()
    private let api = ClashAPI()
    @State private var wakeObserver: WakeObserver?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                singBoxManager: singBoxManager,
                configGenerator: configGenerator,
                api: api
            )
            .environment(appState)
            .task {
                // Setup WakeObserver once
                guard wakeObserver == nil else { return }
                let observer = WakeObserver(
                    singBoxManager: singBoxManager,
                    api: api,
                    configPath: configGenerator.configPath
                )
                wakeObserver = observer
                await observer.startObserving()
            }
        } label: {
            Image(systemName: appState.isRunning ? "shippingbox.fill" : "shippingbox")
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
                Text(appState.errorMessage ?? "")
            }
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            .onDisappear {
                let hasOtherWindow = NSApp.windows.contains { $0.isVisible && $0.title != "BoxX" && $0.title != "" }
                if !hasOtherWindow {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        .defaultSize(width: 900, height: 600)

        Window(String(localized: "menu.settings"), id: "settings") {
            SettingsView()
                .environment(appState)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    let hasOtherWindow = NSApp.windows.contains { $0.isVisible && $0.title != "" }
                    if !hasOtherWindow {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}

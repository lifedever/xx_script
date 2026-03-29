import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var singBoxManager: SingBoxManager?
    var api: ClashAPI?
    var configGenerator: ConfigGenerator?
    var wakeObserver: WakeObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState, let singBoxManager, let api, let configGenerator else { return }
        Task { @MainActor in
            await singBoxManager.refreshStatus()
            appState.isRunning = singBoxManager.isRunning
            appState.pid = singBoxManager.pid
            appState.isHelperInstalled = HelperManager.shared.isHelperInstalled

            let observer = WakeObserver(
                singBoxManager: singBoxManager,
                api: api,
                configPath: configGenerator.configPath
            )
            self.wakeObserver = observer
            await observer.startObserving()
        }
    }
}

@main
struct BoxXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
            .onAppear {
                appDelegate.appState = appState
                appDelegate.singBoxManager = singBoxManager
                appDelegate.api = api
                appDelegate.configGenerator = configGenerator
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
                Text(appState.errorMessage ?? "An unknown error occurred.")
            }
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            .onDisappear {
                // Only go back to accessory if settings window isn't open
                let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue != "" }
                if !hasVisibleWindow {
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
                    let hasVisibleWindow = NSApp.windows.contains {
                        $0.isVisible && $0.title != "" && $0.title != String(localized: "menu.settings")
                    }
                    if !hasVisibleWindow {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}

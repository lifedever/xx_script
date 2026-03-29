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
            // Check status immediately on launch
            await singBoxManager.refreshStatus()
            appState.isRunning = singBoxManager.isRunning
            appState.pid = singBoxManager.pid
            appState.isHelperInstalled = HelperManager.shared.isHelperInstalled

            // Setup WakeObserver
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

    init() {
        // Wire up delegate references (will be used in applicationDidFinishLaunching)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                singBoxManager: singBoxManager,
                configGenerator: configGenerator,
                api: api
            )
            .environment(appState)
            .onAppear {
                // Wire delegate refs on first appear (body is evaluated before didFinishLaunching)
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
            CommandGroup(after: .appInfo) {
                if !appState.isHelperInstalled {
                    Button(String(localized: "menu.install_helper")) {
                        do {
                            try HelperManager.shared.installHelper()
                            appState.isHelperInstalled = true
                        } catch {
                            appState.showAlert(error.localizedDescription)
                        }
                    }
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

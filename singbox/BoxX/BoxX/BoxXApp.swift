import SwiftUI

@main
struct BoxXApp: App {
    private let appState = AppState.shared
    private let singBoxManager = SingBoxManager.shared
    private let configGenerator = ConfigGenerator()
    private let api = ClashAPI()
    @State private var wakeObserver: WakeObserver?
    @State private var statusTimer: Timer?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                singBoxManager: singBoxManager,
                configGenerator: configGenerator,
                api: api
            )
            .environment(appState)
            .onAppear {
                startStatusPolling()
                setupWakeObserver()
            }
        } label: {
            Image(systemName: appState.isRunning ? "shippingbox.fill" : "shippingbox")
        }

        Window("BoxX", id: "main") {
            MainView(api: api, singBoxManager: singBoxManager, configGenerator: configGenerator)
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
                    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
                }
                .onDisappear {
                    let hasOtherWindow = NSApp.windows.contains { $0.isVisible && $0.title != "BoxX" && $0.title != "" }
                    if !hasOtherWindow { NSApp.setActivationPolicy(.accessory) }
                }
        }
        .defaultSize(width: 900, height: 600)

        Window(String(localized: "menu.settings"), id: "settings") {
            SettingsView()
                .environment(appState)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
                .onDisappear {
                    let has = NSApp.windows.contains { $0.isVisible && $0.title != "" }
                    if !has { NSApp.setActivationPolicy(.accessory) }
                }
        }
        .windowResizability(.contentSize)
    }

    private func startStatusPolling() {
        guard statusTimer == nil else { return }
        // Initial check
        Task { @MainActor in
            await singBoxManager.refreshStatus()
            appState.isRunning = singBoxManager.isRunning
            if appState.isRunning {
                // Already running — slow poll (30s) just to detect if it stops
                scheduleSlowPoll()
            } else {
                // Not running — fast poll (3s) until detected
                scheduleFastPoll()
            }
        }
    }

    private func scheduleFastPoll() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in
                await singBoxManager.refreshStatus()
                appState.isRunning = singBoxManager.isRunning
                if appState.isRunning {
                    // Found it — switch to slow poll
                    self.scheduleSlowPoll()
                }
            }
        }
    }

    private func scheduleSlowPoll() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                await singBoxManager.refreshStatus()
                appState.isRunning = singBoxManager.isRunning
                if !appState.isRunning {
                    // Lost it — switch to fast poll
                    self.scheduleFastPoll()
                }
            }
        }
    }

    private func setupWakeObserver() {
        guard wakeObserver == nil else { return }
        let observer = WakeObserver(
            singBoxManager: singBoxManager,
            api: api,
            configPath: configGenerator.configPath
        )
        wakeObserver = observer
        Task { await observer.startObserving() }
    }
}

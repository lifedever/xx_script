import SwiftUI

@main
struct BoxXApp: App {
    private let appState = AppState.shared
    private let singBoxManager = SingBoxManager.shared
    private let configGenerator = ConfigGenerator()
    private let api = ClashAPI()

    init() {
        let manager = singBoxManager
        let state = appState
        let clashAPI = api
        let cfgGen = configGenerator

        Task { @MainActor in
            // Initial status check
            await manager.refreshStatus()
            state.isRunning = manager.isRunning

            // Start adaptive polling
            StatusPoller.shared.start(manager: manager, appState: state)

            // Setup wake observer
            let observer = WakeObserver(singBoxManager: manager, api: clashAPI, configPath: cfgGen.configPath)
            await observer.startObserving()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                singBoxManager: singBoxManager,
                configGenerator: configGenerator,
                api: api
            )
            .environment(appState)
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
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.title != "BoxX" && $0.title != "" }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }
        .defaultSize(width: 900, height: 600)

        Window(String(localized: "menu.settings"), id: "settings") {
            SettingsView()
                .environment(appState)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
                .onDisappear {
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.title != "" }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}

/// Adaptive status polling — fast when stopped, slow when running
@MainActor
final class StatusPoller {
    static let shared = StatusPoller()
    private var timer: Timer?

    func start(manager: SingBoxManager, appState: AppState) {
        guard timer == nil else { return }
        if appState.isRunning {
            // Running — poll slowly (30s) just to detect if it stops
            scheduleSlowPoll(manager: manager, appState: appState)
        } else {
            // Stopped — poll fast (3s) until detected
            scheduleFastPoll(manager: manager, appState: appState)
        }
    }

    /// Call this after any operation that changes state (start/stop/restart/wake)
    func nudge(manager: SingBoxManager, appState: AppState) {
        Task { @MainActor in
            await manager.refreshStatus()
            appState.isRunning = manager.isRunning
            // Reset timer based on new state
            if appState.isRunning {
                scheduleSlowPoll(manager: manager, appState: appState)
            } else {
                scheduleFastPoll(manager: manager, appState: appState)
            }
        }
    }

    private func scheduleFastPoll(manager: SingBoxManager, appState: AppState) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await manager.refreshStatus()
                appState.isRunning = manager.isRunning
                if appState.isRunning {
                    self?.scheduleSlowPoll(manager: manager, appState: appState)
                }
            }
        }
    }

    private func scheduleSlowPoll(manager: SingBoxManager, appState: AppState) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await manager.refreshStatus()
                appState.isRunning = manager.isRunning
                if !appState.isRunning {
                    self?.scheduleFastPoll(manager: manager, appState: appState)
                }
            }
        }
    }
}

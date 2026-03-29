import SwiftUI

@main
struct BoxXApp: App {
    private let appState = AppState.shared

    init() {
        let state = appState

        Task { @MainActor in
            // Load config
            do {
                try state.configEngine.load()
            } catch {
                state.showAlert("Failed to load config: \(error.localizedDescription)")
            }

            // Initial status check via XPC
            let status = await state.xpcClient.getStatus()
            state.isRunning = status.running

            // Start adaptive polling
            StatusPoller.shared.start(appState: state)

            // Start watching config.json for external changes
            state.configEngine.startWatching()

            // Setup wake observer
            let observer = WakeObserver(xpcClient: state.xpcClient, api: state.api)
            await observer.startObserving()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.isRunning ? "shippingbox.fill" : "shippingbox")
        }

        Window("BoxX", id: "main") {
            MainView()
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

/// Adaptive status polling -- fast when stopped, slow when running
@MainActor
final class StatusPoller {
    static let shared = StatusPoller()
    private var timer: Timer?

    func start(appState: AppState) {
        guard timer == nil else { return }
        if appState.isRunning {
            scheduleSlowPoll(appState: appState)
        } else {
            scheduleFastPoll(appState: appState)
        }
    }

    /// Call this after any operation that changes state (start/stop/restart/wake)
    func nudge(appState: AppState) {
        Task { @MainActor in
            let status = await appState.xpcClient.getStatus()
            appState.isRunning = status.running
            if appState.isRunning {
                scheduleSlowPoll(appState: appState)
            } else {
                scheduleFastPoll(appState: appState)
            }
        }
    }

    private func scheduleFastPoll(appState: AppState) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let status = await appState.xpcClient.getStatus()
                appState.isRunning = status.running
                if appState.isRunning {
                    self?.scheduleSlowPoll(appState: appState)
                }
            }
        }
    }

    private func scheduleSlowPoll(appState: AppState) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let status = await appState.xpcClient.getStatus()
                appState.isRunning = status.running
                if !appState.isRunning {
                    self?.scheduleFastPoll(appState: appState)
                }
            }
        }
    }
}

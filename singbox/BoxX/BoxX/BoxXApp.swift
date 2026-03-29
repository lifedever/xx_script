import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var shouldReallyQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shouldReallyQuit { return .terminateNow }
        // Cmd+Q or window close: just hide windows and stay in menu bar
        for window in NSApp.windows where window.isVisible {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }
}

@main
struct BoxXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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

            // Initial status check: XPC first, fallback to Clash API
            // This detects sing-box started by box.sh or other means
            let xpcStatus = await state.xpcClient.getStatus()
            if xpcStatus.running {
                state.isRunning = true
            } else {
                state.isRunning = await state.api.isReachable()
            }

            // Create AppKit menu bar (NSStatusItem + NSMenu for Surge-style layout)
            MenuBarHolder.shared.controller = MenuBarController(appState: state)

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
        .commands {
            CommandMenu("操作") {
                if appState.isRunning {
                    Button("停止") {
                        Task {
                            let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
                            _ = await appState.xpcClient.stop()
                            StatusPoller.shared.nudge(appState: appState)
                        }
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])

                    Button("重启") {
                        Task {
                            _ = await appState.xpcClient.stop()
                            try? await Task.sleep(for: .seconds(1))
                            let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
                            _ = await appState.xpcClient.start(configPath: runtimePath)
                            StatusPoller.shared.nudge(appState: appState)
                        }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                } else {
                    Button("启动") {
                        Task {
                            try? await appState.configEngine.deployRuntime()
                            let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
                            _ = await appState.xpcClient.start(configPath: runtimePath)
                            StatusPoller.shared.nudge(appState: appState)
                        }
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }
        }

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

/// Holds a strong reference to the AppKit MenuBarController so the NSStatusItem stays alive.
@MainActor
final class MenuBarHolder {
    static let shared = MenuBarHolder()
    var controller: MenuBarController?
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

    /// Check running status: try XPC first, fallback to Clash API reachability.
    /// This ensures compatibility with box.sh-started sing-box instances.
    private func checkStatus(appState: AppState) async -> Bool {
        let xpcStatus = await appState.xpcClient.getStatus()
        if xpcStatus.running { return true }
        // Fallback: if XPC helper isn't running or doesn't know about the process,
        // check if Clash API is reachable (box.sh or manually started sing-box)
        return await appState.api.isReachable()
    }

    /// Call this after any operation that changes state (start/stop/restart/wake)
    func nudge(appState: AppState) {
        Task { @MainActor in
            appState.isRunning = await checkStatus(appState: appState)
            MenuBarHolder.shared.controller?.updateIcon()
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
                guard let self else { return }
                appState.isRunning = await self.checkStatus(appState: appState)
                MenuBarHolder.shared.controller?.updateIcon()
                if appState.isRunning {
                    self.scheduleSlowPoll(appState: appState)
                }
            }
        }
    }

    private func scheduleSlowPoll(appState: AppState) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                appState.isRunning = await self.checkStatus(appState: appState)
                MenuBarHolder.shared.controller?.updateIcon()
                if !appState.isRunning {
                    self.scheduleFastPoll(appState: appState)
                }
            }
        }
    }
}

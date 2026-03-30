import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var shared: AppDelegate?
    var shouldReallyQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shouldReallyQuit { return .terminateNow }
        // Cmd+Q: only hide app windows (not system/internal windows like NSStatusBarWindow)
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            window.orderOut(nil)
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
        // Clean up v1 legacy UserDefaults keys that trigger TCC prompts
        UserDefaults.standard.removeObject(forKey: "scriptDir")

        // Apply saved appearance mode (deferred until NSApp is ready)
        DispatchQueue.main.async { applySavedAppearance() }

        let state = appState

        Task { @MainActor in
            // Register XPC Helper (tries SMAppService, falls back to osascript)

            // Load config
            do {
                try state.configEngine.load()
            } catch {
                state.showAlert("Failed to load config: \(error.localizedDescription)")
            }

            // Initial status check: see if sing-box is already running
            state.isRunning = await state.singBoxProcess.refreshStatus()

            // Create AppKit menu bar (NSStatusItem + NSMenu for Surge-style layout)
            MenuBarHolder.shared.controller = MenuBarController(appState: state)

            // Start adaptive polling
            StatusPoller.shared.start(appState: state)

            // Start watching config.json for external changes
            state.configEngine.startWatching()

            // Setup wake observer
            let observer = WakeObserver(singBoxProcess: state.singBoxProcess, api: state.api, configEngine: state.configEngine)
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
                            await appState.singBoxProcess.stop()
                            StatusPoller.shared.nudge(appState: appState)
                        }
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])

                    Button("重启") {
                        Task {
                            do {
                                try appState.configEngine.deployRuntime()
                                let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
                                try await appState.singBoxProcess.restart(configPath: runtimePath, mixedPort: appState.configEngine.mixedPort)
                            } catch {
                                appState.showAlert(error.localizedDescription)
                            }
                            StatusPoller.shared.nudge(appState: appState)
                        }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                } else {
                    Button("启动") {
                        Task {
                            do {
                                try appState.configEngine.deployRuntime()
                                let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
                                try await appState.singBoxProcess.start(configPath: runtimePath, mixedPort: appState.configEngine.mixedPort)
                            } catch {
                                appState.showAlert(error.localizedDescription)
                            }
                            StatusPoller.shared.nudge(appState: appState)
                        }
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                }

                Divider()

                Button("监控") {
                    openMonitorWindow()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }

        Window("监控", id: "monitor") {
            MonitorView()
                .environment(appState)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
                .onDisappear {
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
                .handlesExternalEvents(preferring: ["monitor"], allowing: ["monitor"])
        }
        .defaultSize(width: 900, height: 500)
        .handlesExternalEvents(matching: ["monitor"])

        Window("更新日志", id: "update-log") {
            SubscriptionUpdateLogView()
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
                .onDisappear {
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }
        .defaultSize(width: 500, height: 300)

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

/// Open the monitor window (works from App commands, AppKit menus, and SwiftUI views)
@MainActor
func openMonitorWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    // If monitor window already exists, just bring it forward
    for window in NSApp.windows where window.title == "监控" {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return
    }
    // Otherwise post notification so SwiftUI openWindow can handle it
    NotificationCenter.default.post(name: .openMonitorWindow, object: nil)
}

extension Notification.Name {
    static let openMonitorWindow = Notification.Name("com.boxx.openMonitorWindow")
    static let subscriptionLogAppend = Notification.Name("com.boxx.subscriptionLogAppend")
    static let subscriptionLogStart = Notification.Name("com.boxx.subscriptionLogStart")
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

    /// Check running status via SingBoxProcess (managed process or Clash API fallback)
    private func checkStatus(appState: AppState) async -> Bool {
        return await appState.singBoxProcess.refreshStatus()
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

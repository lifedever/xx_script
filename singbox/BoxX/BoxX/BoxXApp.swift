import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var shared: AppDelegate?
    var shouldReallyQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shouldReallyQuit { return .terminateNow }
        // Hide all windows, keep menu bar alive
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

            // Load config and regenerate runtime-config.json (picks up code changes)
            do {
                try state.configEngine.load()
                try state.configEngine.deployRuntime(skipValidation: true)
            } catch {
                state.showAlert("Failed to load config: \(error.localizedDescription)")
            }

            // Migrate legacy launchd daemon to XPC Helper (one-time)
            await state.singBoxProcess.migrateLegacyDaemon()

            // Initial status check: see if sing-box is already running (via XPC Helper)
            state.isRunning = await state.singBoxProcess.refreshStatus()

            // Create AppKit menu bar (NSStatusItem + NSMenu for Surge-style layout)
            MenuBarHolder.shared.controller = MenuBarController(appState: state)

            // Start adaptive polling
            StatusPoller.shared.start(appState: state)

            // Startup complete — enable auto-apply for config changes
            state.startupComplete = true

            // Start watching config.json for external changes (delay to avoid race during startup)
            try? await Task.sleep(for: .seconds(3))
            state.configEngine.startWatching()

            // Request notification permission
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

            // Setup wake observer (must retain reference)
            let observer = WakeObserver(singBoxProcess: state.singBoxProcess, api: state.api, configEngine: state.configEngine)
            await observer.startObserving()
            WakeObserverHolder.shared.observer = observer
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
                                appState.singBoxProcess.flushDNS()
                                try? await appState.api.closeAllConnections()
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
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
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
    // If monitor window already exists, just bring it forward and tell views to reconnect
    for window in NSApp.windows where window.title == "监控" {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NotificationCenter.default.post(name: .monitorWindowOpened, object: nil)
        return
    }
    // Otherwise post notification so SwiftUI openWindow can handle it
    NotificationCenter.default.post(name: .openMonitorWindow, object: nil)
}

extension Notification.Name {
    static let openMonitorWindow = Notification.Name("com.boxx.openMonitorWindow")
    static let subscriptionLogAppend = Notification.Name("com.boxx.subscriptionLogAppend")
    static let subscriptionLogStart = Notification.Name("com.boxx.subscriptionLogStart")
    static let subscriptionUpdateFailed = Notification.Name("com.boxx.subscriptionUpdateFailed")
    static let subscriptionRetry = Notification.Name("com.boxx.subscriptionRetry")
    static let monitorWindowOpened = Notification.Name("com.boxx.monitorWindowOpened")
}

/// Holds a strong reference to the AppKit MenuBarController so the NSStatusItem stays alive.
@MainActor
final class MenuBarHolder {
    static let shared = MenuBarHolder()
    var controller: MenuBarController?
}

/// Holds a strong reference to WakeObserver so it's not released by ARC.
@MainActor
final class WakeObserverHolder {
    static let shared = WakeObserverHolder()
    var observer: WakeObserver?
}

/// XPC-based status monitor — watches sing-box process exit via Helper (zero CPU)
@MainActor
final class StatusPoller {
    static let shared = StatusPoller()
    private var watchTask: Task<Void, Never>?

    func start(appState: AppState) {
        Task { @MainActor in
            appState.isRunning = await appState.singBoxProcess.refreshStatus()
            MenuBarHolder.shared.controller?.updateIcon()
            if appState.isRunning {
                startWatchLoop(appState: appState)
            }
        }
    }

    /// Call this after any operation that changes state (start/stop/restart/wake)
    func nudge(appState: AppState) {
        Task { @MainActor in
            appState.isRunning = await appState.singBoxProcess.refreshStatus()
            MenuBarHolder.shared.controller?.updateIcon()
            if appState.isRunning {
                startWatchLoop(appState: appState)
            } else {
                stopWatchLoop()
            }
        }
    }

    private func startWatchLoop(appState: AppState) {
        // Don't start duplicate watch loops
        guard watchTask == nil else { return }
        watchTask = Task { @MainActor in
            while !Task.isCancelled {
                // Block until sing-box exits (Helper holds the XPC reply)
                let (_, _) = await appState.singBoxProcess.watchProcessExit()

                guard !Task.isCancelled else { break }

                // Process exited — refresh status (Helper may have auto-restarted it)
                try? await Task.sleep(for: .seconds(1))
                appState.isRunning = await appState.singBoxProcess.refreshStatus()
                MenuBarHolder.shared.controller?.updateIcon()

                if !appState.isRunning {
                    // Process is gone, stop watching
                    break
                }
                // If still running (auto-restarted), loop continues watching
            }
            watchTask = nil
        }
    }

    private func stopWatchLoop() {
        watchTask?.cancel()
        watchTask = nil
    }
}

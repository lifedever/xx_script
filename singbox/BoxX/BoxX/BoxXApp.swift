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
        // Notify views to stop background work (WebSocket, timers)
        NotificationCenter.default.post(name: .allWindowsHidden, object: nil)
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
            // Load config and regenerate runtime-config.json (picks up code changes)
            do {
                try state.configEngine.load()
                try state.configEngine.deployRuntime(skipValidation: true)
            } catch {
                state.showAlert("Failed to load config: \(error.localizedDescription)")
            }

            // Create AppKit menu bar first (so UI is always responsive)
            MenuBarHolder.shared.controller = MenuBarController(appState: state)

            // Ensure XPC Helper is installed AND running (before any XPC calls)
            let needsInstall: Bool
            if !state.singBoxProcess.isHelperInstalled() {
                print("[BoxX] Helper files not found on disk")
                needsInstall = true
            } else if !(await state.singBoxProcess.isHelperResponding()) {
                print("[BoxX] Helper files exist but daemon not responding")
                needsInstall = true
            } else {
                needsInstall = false
            }

            if needsInstall {
                print("[BoxX] Installing/re-registering Helper...")
                let installed = await state.singBoxProcess.installHelper()
                if !installed {
                    state.showAlert("Helper 安装失败。请在「设置 → Helper 服务」中重新安装，或运行 ./build.sh full")
                }
            }

            // Migrate legacy launchd daemon to XPC Helper (one-time)
            await state.singBoxProcess.migrateLegacyDaemon()

            // Now safe to use XPC — check if sing-box is already running
            state.isRunning = await state.singBoxProcess.refreshStatus()
            MenuBarHolder.shared.controller?.updateIcon()

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
    static let allWindowsHidden = Notification.Name("com.boxx.allWindowsHidden")
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
/// Also runs a periodic heartbeat to detect zombie/hung sing-box processes.
@MainActor
final class StatusPoller {
    static let shared = StatusPoller()
    private var watchTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    /// Consecutive heartbeat failures before declaring zombie
    private static let maxFailures = 3
    /// Heartbeat check interval in seconds
    private static let heartbeatInterval: Duration = .seconds(30)

    func start(appState: AppState) {
        Task { @MainActor in
            appState.isRunning = await appState.singBoxProcess.refreshStatus()
            MenuBarHolder.shared.controller?.updateIcon()
            if appState.isRunning {
                startWatchLoop(appState: appState)
                startHeartbeat(appState: appState)
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
                startHeartbeat(appState: appState)
            } else {
                stopAll()
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
                    stopHeartbeat()
                    break
                }
                // If still running (auto-restarted), loop continues watching
            }
            watchTask = nil
        }
    }

    // MARK: - Heartbeat (zombie detection + outbound health)

    /// Outbound connectivity check interval (less frequent than API heartbeat)
    private static let outboundCheckInterval: Duration = .seconds(90)

    private func startHeartbeat(appState: AppState) {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor in
            var consecutiveFailures = 0
            var consecutiveOutboundFailures = 0
            var tickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled else { break }

                // Only check when we think sing-box is running
                guard appState.isRunning else { break }

                // 1. Clash API heartbeat (every 30s)
                let alive = await Self.pingClashAPI()
                if alive {
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    print("[BoxX] Heartbeat failed (\(consecutiveFailures)/\(Self.maxFailures))")

                    if consecutiveFailures >= Self.maxFailures {
                        print("[BoxX] sing-box unresponsive, forcing restart...")
                        await appState.singBoxProcess.stop()
                        consecutiveFailures = 0
                        consecutiveOutboundFailures = 0

                        try? await Task.sleep(for: .seconds(4))
                        appState.isRunning = await appState.singBoxProcess.refreshStatus()
                        MenuBarHolder.shared.controller?.updateIcon()

                        if !appState.isRunning { break }
                    }
                    continue
                }

                // 2. Outbound connectivity check (every ~90s: 3 ticks of 30s)
                tickCount += 1
                guard tickCount >= 3 else { continue }
                tickCount = 0

                let outboundOK = await Self.probeOutbound(port: appState.configEngine.mixedPort)
                if outboundOK {
                    consecutiveOutboundFailures = 0
                } else {
                    consecutiveOutboundFailures += 1
                    print("[BoxX] Outbound probe failed (\(consecutiveOutboundFailures)/2)")

                    if consecutiveOutboundFailures >= 2 {
                        print("[BoxX] Outbound broken, attempting SIGHUP recovery...")
                        await appState.singBoxProcess.reload()
                        appState.singBoxProcess.flushDNS()
                        try? await appState.api.closeAllConnections()
                        try? await Task.sleep(for: .seconds(3))

                        let recovered = await Self.probeOutbound(port: appState.configEngine.mixedPort)
                        if recovered {
                            print("[BoxX] SIGHUP recovery succeeded")
                            consecutiveOutboundFailures = 0
                        } else {
                            print("[BoxX] SIGHUP failed, performing full restart...")
                            let rtPath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
                            let mixedPort = appState.configEngine.mixedPort
                            await appState.singBoxProcess.stop()
                            try? await Task.sleep(for: .seconds(2))
                            try? await appState.singBoxProcess.start(configPath: rtPath, mixedPort: mixedPort)
                            appState.singBoxProcess.flushDNS()
                            consecutiveOutboundFailures = 0

                            try? await Task.sleep(for: .seconds(3))
                            appState.isRunning = await appState.singBoxProcess.refreshStatus()
                            MenuBarHolder.shared.controller?.updateIcon()
                            if !appState.isRunning { break }
                        }
                    }
                }
            }
            heartbeatTask = nil
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func stopWatchLoop() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func stopAll() {
        stopWatchLoop()
        stopHeartbeat()
    }

    /// Probe actual outbound connectivity through the proxy
    private nonisolated static func probeOutbound(port: Int) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort: port,
        ] as [String: Any]
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let url = URL(string: "http://www.gstatic.com/generate_204")!
            let (_, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 204 || http.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    /// Ping Clash API to check if sing-box is responsive
    private nonisolated static func pingClashAPI() async -> Bool {
        await withCheckedContinuation { cont in
            guard let url = URL(string: "http://127.0.0.1:9091/version") else {
                cont.resume(returning: false)
                return
            }
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            let task = session.dataTask(with: URLRequest(url: url, timeoutInterval: 5)) { _, response, _ in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                cont.resume(returning: ok)
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }
}

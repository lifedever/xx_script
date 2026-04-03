import Foundation
import AppKit
import Network

actor WakeObserver {
    private let singBoxProcess: SingBoxProcess
    private let api: ClashAPI
    private let configEngine: ConfigEngine
    private var isRecovering = false
    private var observation: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var pendingPathChange: Task<Void, Never>?
    private let logFile: String = {
        let fm = FileManager.default
        let sharedDir = "/Library/Application Support/BoxX"
        let userDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BoxX").path
        let dir = fm.isWritableFile(atPath: sharedDir) ? sharedDir : userDir
        return "\(dir)/boxx-wake.log"
    }()

    init(singBoxProcess: SingBoxProcess, api: ClashAPI, configEngine: ConfigEngine) {
        self.singBoxProcess = singBoxProcess
        self.api = api
        self.configEngine = configEngine
    }

    func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        observation = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleWake() }
        }

        // Monitor network path changes (Wi-Fi switch, hotspot, cable plug/unplug)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.handlePathChange(path) }
        }
        monitor.start(queue: DispatchQueue(label: "com.boxx.network-monitor"))
        pathMonitor = monitor
    }

    func stopObserving() {
        if let observation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        observation = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func handlePathChange(_ path: NWPath) async {
        let newStatus = path.status

        // Skip the initial callback and only react to actual changes
        guard let previous = lastPathStatus else {
            lastPathStatus = newStatus
            return
        }
        lastPathStatus = newStatus

        // Only recover when network becomes satisfied (reconnected)
        guard newStatus == .satisfied, previous != .satisfied else {
            if newStatus != .satisfied {
                log("Network lost: \(newStatus)")
            }
            return
        }

        // Debounce: cancel any pending recovery and wait 3s for network to stabilize.
        // Prevents rapid unsatisfied↔satisfied flips from spawning multiple concurrent recoveries
        // which can race with SwiftUI rendering and cause EXC_BAD_ACCESS.
        pendingPathChange?.cancel()
        pendingPathChange = Task {
            log("Network restored, waiting 3s for stabilization...")
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await recover(source: "network-change")
        }
    }

    private func handleWake() async {
        log("Wake detected, waiting 3s for interfaces...")
        try? await Task.sleep(for: .seconds(3))
        await recover(source: "wake")
    }

    private func recover(source: String) async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }

        let apiReachable = await api.isReachable()
        log("[\(source)] Clash API reachable: \(apiReachable)")

        if !apiReachable {
            log("[\(source)] Process dead, cannot auto-restart")
            return
        }

        // Step 1: SIGHUP 热重载 + 刷 DNS + 清连接（对齐菜单热重载逻辑）
        log("[\(source)] Step 1: SIGHUP hot-reload + flush DNS + close connections")
        await reloadOnMain()
        await flushDNSOnMain()
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(3))

        let test1 = await probeWithRetry(label: "[\(source)] Step 1")
        if test1 { return }

        // Step 2: 重载配置文件（重建所有 outbound 连接池）
        log("[\(source)] Step 2: reload config + flush DNS + close connections")
        let runtimePath = await MainActor.run { configEngine.baseDir.appendingPathComponent("runtime-config.json").path }
        try? await api.reloadConfig(path: runtimePath)
        await flushDNSOnMain()
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(3))

        let test2 = await probeWithRetry(label: "[\(source)] Step 2")
        if test2 { return }

        // Step 3: 通过 XPC Helper 完全重启进程（stop + start），彻底销毁出站连接池
        log("[\(source)] Step 3: full process restart via XPC Helper (stop + start)")
        let configPath = await MainActor.run { configEngine.baseDir.appendingPathComponent("runtime-config.json").path }
        let mixedPort = await MainActor.run { configEngine.mixedPort }
        await stopOnMain()
        try? await Task.sleep(for: .seconds(2))
        let startError = await startOnMain(configPath: configPath, mixedPort: mixedPort)
        if let error = startError {
            log("[\(source)] Step 3 restart failed: \(error)")
        }
        try? await Task.sleep(for: .seconds(3))
        await flushDNSOnMain()

        let test3 = await probeWithRetry(label: "[\(source)] Step 3")
        if test3 { return }

        log("[\(source)] All recovery steps failed, user may need to manually restart")
    }

    // MARK: - MainActor bridges (actor → @MainActor async calls)

    private func reloadOnMain() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await singBoxProcess.reload()
                cont.resume()
            }
        }
    }

    private func stopOnMain() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await singBoxProcess.stop()
                cont.resume()
            }
        }
    }

    private func startOnMain(configPath: String, mixedPort: Int) async -> Error? {
        await withCheckedContinuation { (cont: CheckedContinuation<Error?, Never>) in
            Task { @MainActor in
                do {
                    try await singBoxProcess.start(configPath: configPath, mixedPort: mixedPort)
                    cont.resume(returning: nil)
                } catch {
                    cont.resume(returning: error)
                }
            }
        }
    }

    private func flushDNSOnMain() async {
        await MainActor.run { singBoxProcess.flushDNS() }
    }

    private func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFile, contents: data)
            }
        }
    }

    /// Probe with up to 3 retries, 2s apart. Logs each attempt.
    private func probeWithRetry(label: String, maxAttempts: Int = 3) async -> Bool {
        for attempt in 1...maxAttempts {
            let ok = await probeExternalConnectivity()
            if ok {
                log("\(label) probe \(attempt)/\(maxAttempts): OK")
                return true
            }
            log("\(label) probe \(attempt)/\(maxAttempts): FAIL")
            if attempt < maxAttempts {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        return false
    }

    private func probeExternalConnectivity() async -> Bool {
        let port = await MainActor.run { configEngine.mixedPort }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort: port,
        ] as [String: Any]
        config.timeoutIntervalForRequest = 10

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
}

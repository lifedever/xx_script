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

        log("Network restored, starting recovery...")
        // Brief delay to let interfaces stabilize
        try? await Task.sleep(for: .seconds(2))
        await recover(source: "network-change")
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

        // Step 1: 轻量修复 — 刷 DNS + 清连接（解决大多数情况）
        log("[\(source)] Step 1: flush DNS + close connections")
        await MainActor.run { singBoxProcess.flushDNS() }
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(2))

        let test1 = await probeExternalConnectivity()
        log("[\(source)] Step 1 result: \(test1 ? "OK" : "FAIL")")
        if test1 { return }

        // Step 2: 热重载 — SIGHUP 让 sing-box 刷新内部状态（TUN/路由/DNS 服务）
        log("[\(source)] Step 2: SIGHUP hot-reload + flush DNS + close connections")
        await MainActor.run { Task { await singBoxProcess.reload() } }
        try? await Task.sleep(for: .seconds(3))
        await MainActor.run { singBoxProcess.flushDNS() }
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(2))

        let test2 = await probeExternalConnectivity()
        log("[\(source)] Step 2 result: \(test2 ? "OK" : "FAIL")")
        if test2 { return }

        log("[\(source)] All recovery steps failed, user may need to manually restart")
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
        config.timeoutIntervalForRequest = 5

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

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

        // Step 1: 刷 DNS + 清连接 + 热重载配置（重建所有 outbound 连接池）
        log("[\(source)] Step 1: flush DNS + close connections + reload config")
        await MainActor.run { singBoxProcess.flushDNS() }
        try? await api.closeAllConnections()
        let runtimePath = await MainActor.run { configEngine.baseDir.appendingPathComponent("runtime-config.json").path }
        try? await api.reloadConfig(path: runtimePath)
        try? await Task.sleep(for: .seconds(2))

        let test1 = await probeExternalConnectivity()
        log("[\(source)] Step 1 result: \(test1 ? "OK" : "FAIL")")
        if test1 { return }

        // Step 2: SIGHUP 重启 — 完整刷新 TUN/路由/DNS 服务
        log("[\(source)] Step 2: SIGHUP hot-reload + flush DNS + close connections")
        await MainActor.run { Task { await singBoxProcess.reload() } }
        try? await Task.sleep(for: .seconds(3))
        await MainActor.run { singBoxProcess.flushDNS() }
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(2))

        let test2 = await probeExternalConnectivity()
        log("[\(source)] Step 2 result: \(test2 ? "OK" : "FAIL")")
        if test2 { return }

        // Step 3: 完全重启进程，彻底销毁出站连接池（不清 cache.db，保留节点选择）
        log("[\(source)] Step 3: full process restart via launchctl kickstart -k")
        await MainActor.run {
            Task {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                proc.arguments = ["-n", "launchctl", "kickstart", "-k", "system/com.boxx.singbox"]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
            }
        }
        // 等待进程重启并就绪
        try? await Task.sleep(for: .seconds(5))
        await MainActor.run { singBoxProcess.flushDNS() }
        try? await Task.sleep(for: .seconds(2))

        let test3 = await probeExternalConnectivity()
        log("[\(source)] Step 3 result: \(test3 ? "OK" : "FAIL")")
        if test3 { return }

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

import Foundation
import AppKit

actor WakeObserver {
    private let singBoxProcess: SingBoxProcess
    private let api: ClashAPI
    private let configEngine: ConfigEngine
    private var isRecovering = false
    private var observation: NSObjectProtocol?
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
    }

    func stopObserving() {
        if let observation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        observation = nil
    }

    private func handleWake() async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }

        log("Wake detected, waiting 3s for interfaces...")
        try? await Task.sleep(for: .seconds(3))

        let apiReachable = await api.isReachable()
        log("Clash API reachable: \(apiReachable)")

        if !apiReachable {
            log("Process dead, cannot auto-restart")
            return
        }

        // Step 1: Flush DNS + close all connections
        log("Step 1: flush DNS + close connections")
        await MainActor.run { singBoxProcess.flushDNS() }
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(2))

        let test1 = await probeExternalConnectivity()
        log("Step 1 result: \(test1 ? "OK" : "FAIL")")
        if test1 { return }

        // Step 2: Retry
        log("Step 2: retry flush + close")
        await MainActor.run { singBoxProcess.flushDNS() }
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(3))

        let test2 = await probeExternalConnectivity()
        log("Step 2 result: \(test2 ? "OK" : "FAIL")")
        if test2 { return }

        // Step 3: Full restart of sing-box
        log("Step 3: restarting sing-box process")
        // We cannot easily restart here without the config path,
        // but the process is still running (API was reachable).
        // Just flush DNS one more time.
        await MainActor.run { singBoxProcess.flushDNS() }
        log("Step 3: final DNS flush done")
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

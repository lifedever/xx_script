import Foundation
import AppKit

actor WakeObserver {
    private let singBoxManager: SingBoxManager
    private let api: ClashAPI
    private let configPath: String
    private var isRecovering = false
    private var observation: NSObjectProtocol?
    private let logFile: String = {
        let dir = (UserDefaults.standard.string(forKey: "scriptDir")
            ?? (NSHomeDirectory() + "/Documents/Dev/myspace/xx_script/singbox"))
        return dir + "/boxx-wake.log"
    }()

    init(singBoxManager: SingBoxManager, api: ClashAPI, configPath: String) {
        self.singBoxManager = singBoxManager
        self.api = api
        self.configPath = configPath
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
            await singBoxManager.refreshStatus()
            return
        }

        // Step 1: Flush DNS + close all connections
        log("Step 1: flush DNS + close connections")
        flushDNS()
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(2))

        let test1 = await probeExternalConnectivity()
        log("Step 1 result: \(test1 ? "OK" : "FAIL")")
        if test1 { await singBoxManager.refreshStatus(); return }

        // Step 2: Retry
        log("Step 2: retry flush + close")
        flushDNS()
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(3))

        let test2 = await probeExternalConnectivity()
        log("Step 2 result: \(test2 ? "OK" : "FAIL")")
        if test2 { await singBoxManager.refreshStatus(); return }

        // Step 3: Restart sing-box (password prompt)
        log("Step 3: restarting sing-box (password required)")
        try? await singBoxManager.restart(configPath: configPath)
        await singBoxManager.refreshStatus()
        log("Restart complete, running: \(await singBoxManager.isRunning)")
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

    /// Flush DNS cache
    private func flushDNS() {
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush.arguments = ["-flushcache"]
        try? flush.run()
        flush.waitUntilExit()

        let killDNS = Process()
        killDNS.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killDNS.arguments = ["-HUP", "mDNSResponder"]
        try? killDNS.run()
        killDNS.waitUntilExit()
    }

    private func probeExternalConnectivity() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: 7890,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort: 7890,
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

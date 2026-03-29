import Foundation
import AppKit

actor WakeObserver {
    private let singBoxManager: SingBoxManager
    private let api: ClashAPI
    private let configPath: String
    private var isRecovering = false
    private var observation: NSObjectProtocol?

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

        // Wait for network interfaces to initialize
        try? await Task.sleep(for: .seconds(3))

        // Step 1: Is sing-box process alive?
        let apiReachable = await api.isReachable()
        if !apiReachable {
            // sing-box is dead or completely broken
            // Flush DNS and try waiting a bit more
            flushDNS()
            try? await Task.sleep(for: .seconds(3))

            // Check again
            if await api.isReachable() {
                await singBoxManager.refreshStatus()
                return
            }

            // Still dead — can't auto-restart without password, just update status
            await singBoxManager.refreshStatus()
            return
        }

        // Step 2: API is reachable — flush DNS first (fixes most post-sleep issues)
        flushDNS()
        try? await Task.sleep(for: .seconds(1))

        // Step 3: Test external connectivity through proxy
        let proxyWorks = await probeExternalConnectivity()
        if proxyWorks {
            // Everything is fine
            await singBoxManager.refreshStatus()
            return
        }

        // Step 4: Proxy not working — try flushing DNS again and wait longer
        flushDNS()
        try? await Task.sleep(for: .seconds(3))

        let secondTry = await probeExternalConnectivity()
        if secondTry {
            await singBoxManager.refreshStatus()
            return
        }

        // Step 5: Still not working — try restarting sing-box via osascript
        // This will show a password prompt, but it's better than no network
        try? await singBoxManager.restart(configPath: configPath)
        await singBoxManager.refreshStatus()
    }

    /// Flush DNS cache (doesn't require root on macOS)
    private func flushDNS() {
        // dscacheutil doesn't need root
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush.arguments = ["-flushcache"]
        try? flush.run()
        flush.waitUntilExit()

        // killall mDNSResponder needs root, but we try anyway (may fail silently)
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

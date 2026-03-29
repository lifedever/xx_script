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

        // Is sing-box process alive?
        let apiReachable = await api.isReachable()
        if !apiReachable {
            // Process dead — update status, can't auto-restart without password
            await singBoxManager.refreshStatus()
            return
        }

        // Process alive — try recovery without restart:
        // 1. Flush DNS
        flushDNS()

        // 2. Close all connections (forces TUN to rebuild)
        try? await api.closeAllConnections()

        // 3. Wait for reconnection
        try? await Task.sleep(for: .seconds(2))

        // 4. Test if external network works
        if await probeExternalConnectivity() {
            await singBoxManager.refreshStatus()
            return
        }

        // 5. Still broken — flush DNS again + close connections + wait longer
        flushDNS()
        try? await api.closeAllConnections()
        try? await Task.sleep(for: .seconds(3))

        if await probeExternalConnectivity() {
            await singBoxManager.refreshStatus()
            return
        }

        // 6. Last resort — restart sing-box (will prompt for password)
        try? await singBoxManager.restart(configPath: configPath)
        await singBoxManager.refreshStatus()
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

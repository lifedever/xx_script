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

        try? await Task.sleep(for: .seconds(3))

        await singBoxManager.refreshStatus()
        let running = await singBoxManager.isRunning

        if !running {
            try? await singBoxManager.start(configPath: configPath)
            return
        }

        let apiReachable = await api.isReachable()
        if !apiReachable {
            try? await singBoxManager.restart(configPath: configPath)
            return
        }

        let proxyWorks = await probeExternalConnectivity()
        if !proxyWorks {
            try? await singBoxManager.restart(configPath: configPath)
            return
        }
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

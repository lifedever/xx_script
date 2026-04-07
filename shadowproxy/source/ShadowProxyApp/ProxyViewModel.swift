import Foundation
import SwiftUI
import ShadowProxyCore

@MainActor
final class ProxyViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var statusText = "Stopped"
    @Published var logMessages: [String] = []
    @Published var proxyGroups: [ProxyGroup] = []
    @Published var selectedNodes: [String: String] = [:]
    @Published var proxyNames: [String] = []
    @Published var configLoaded = false
    @Published var ruleCount = 0
    @Published var nodeSpeeds: [String: Int] = [:]
    @Published var requestRecords: [RequestRecord] = []
    @Published var isTestingSpeed = false
    @Published var subscriptions: [SubscriptionInfo] = []
    private let maxRecords = 2000
    private let subscriptionManager = SubscriptionManager()

    @AppStorage("proxyPort") var settingsPort: Int = 7891
    @AppStorage("dnsServer") var settingsDNS: String = "https://223.5.5.5/dns-query"
    @AppStorage("logLevel") var settingsLogLevel: String = "info"
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("autoRefreshSubs") var autoRefreshSubs: Bool = true

    private var config: AppConfig?
    private var expandedRuleSets: [String: [Rule]] = [:]
    private var engine: ProxyEngine?
    private var sleepWatcher: SleepWatcher?
    private let configPath = NSHomeDirectory() + "/.shadowproxy/config.conf"
    private var port: UInt16 = 7890

    /// App 启动时调用，加载配置并显示
    func loadConfig() {
        // Initialize file logger
        let logPath = NSHomeDirectory() + "/.shadowproxy/shadowproxy.log"
        splog.level = .debug
        splog.setLogFile(logPath)
        splog.onLog = { [weak self] message in
            Task { @MainActor in
                self?.logMessages.append(message)
                if (self?.logMessages.count ?? 0) > 500 {
                    self?.logMessages.removeFirst((self?.logMessages.count ?? 500) - 500)
                }
            }
        }
        splog.info("ShadowProxy App starting", tag: "App")
        guard FileManager.default.fileExists(atPath: configPath) else {
            log("Config not found: \(configPath)")
            return
        }

        let parser = ConfigParser()
        do {
            let config = try parser.parse(fileAt: configPath)
            self.config = config
            self.configLoaded = true
            self.port = config.general.port

            proxyGroups = config.groups
            proxyNames = Array(config.proxies.keys).sorted()
            ruleCount = config.rules.count

            // Init selected nodes from first member of each group
            for group in config.groups {
                if selectedNodes[group.name] == nil, let first = group.members.first {
                    selectedNodes[group.name] = first
                }
            }

            log("Loaded \(config.proxies.count) proxies, \(config.groups.count) groups, \(config.rules.count) rules")
        } catch {
            log("Config parse error: \(error)")
        }

        // Load RULE-SET in background
        Task {
            guard let config = self.config else { return }
            let ruleSetURLs = config.rules.compactMap { rule -> (url: String, policy: String)? in
                if case .ruleSet(let url, let policy) = rule { return (url, policy) }
                return nil
            }

            if !ruleSetURLs.isEmpty {
                log("Loading \(ruleSetURLs.count) rule sets...")
                let loader = RuleSetLoader(cacheDir: NSHomeDirectory() + "/.shadowproxy/rulesets")
                self.expandedRuleSets = await loader.loadAll(ruleSets: ruleSetURLs)
                let total = self.expandedRuleSets.values.reduce(0) { $0 + $1.count }
                self.ruleCount = config.rules.count + total
                log("Loaded \(total) rules from rule sets")
            }
        }

        loadSubscriptions()
    }

    func start() {
        guard !isRunning, let config else { return }

        log("Starting proxy...")

        Task {
            let engine = ProxyEngine(config: config, port: port, expandedRuleSets: expandedRuleSets)

            engine.onRequest = { [weak self] record in
                Task { @MainActor in
                    self?.appendRequest(record)
                }
            }

            do {
                try engine.start()
                self.engine = engine
                self.isRunning = true
                (NSApp.delegate as? AppDelegate)?.updateStatusIcon(running: true)
                self.statusText = "Running — 127.0.0.1:\(port)"
                log("Proxy started on port \(port)")
            } catch {
                log("Start failed: \(error)")
                return
            }

            // Set system proxy
            do {
                try SystemProxy.enable(port: port)
                log("System proxy enabled")
            } catch {
                log("System proxy failed: \(error)")
            }

            // Sleep watcher
            let watcher = SleepWatcher {
                self.log("Wake detected, checking proxy...")
                if !SystemProxy.isEnabled(port: self.port) {
                    try? SystemProxy.enable(port: self.port)
                    self.log("System proxy restored")
                }
            }
            watcher.start()
            self.sleepWatcher = watcher
        }
    }

    func stop() {
        guard isRunning else { return }

        engine?.stop()
        engine = nil
        sleepWatcher?.stop()
        sleepWatcher = nil

        do {
            try SystemProxy.disable()
            log("System proxy disabled")
        } catch {
            log("Failed to disable system proxy: \(error)")
        }

        isRunning = false
        (NSApp.delegate as? AppDelegate)?.updateStatusIcon(running: false)
        statusText = "Stopped"
        log("Proxy stopped")
    }

    func selectNode(group: String, node: String) {
        selectedNodes[group] = node
        engine?.select(group: group, node: node)
        log("Selected \(node) for \(group)")
    }

    func reload() {
        stop()
        loadConfig()
        start()
        log("Configuration reloaded")
    }

    func appendRequest(_ record: RequestRecord) {
        requestRecords.append(record)
        if requestRecords.count > maxRecords {
            requestRecords.removeFirst(requestRecords.count - maxRecords)
        }
    }

    func log(_ message: String) {
        splog.info(message, tag: "App")
    }

    // MARK: - Subscriptions

    func loadSubscriptions() {
        subscriptions = subscriptionManager.subscriptions()
    }

    func addSubscription(name: String, url: String) async {
        do {
            try await subscriptionManager.add(name: name, url: url)
            subscriptions = subscriptionManager.subscriptions()
            log("Added subscription: \(name)")
        } catch {
            log("Add subscription failed: \(error)")
        }
    }

    func refreshSubscription(id: String) async {
        do {
            try await subscriptionManager.refresh(id: id)
            subscriptions = subscriptionManager.subscriptions()
        } catch {
            log("Refresh failed: \(error)")
        }
    }

    func refreshAllSubscriptions() async {
        do {
            try await subscriptionManager.refreshAll()
            subscriptions = subscriptionManager.subscriptions()
        } catch {
            log("Refresh all failed: \(error)")
        }
    }

    func deleteSubscription(id: String) {
        subscriptionManager.delete(id: id)
        subscriptions = subscriptionManager.subscriptions()
    }

    // MARK: - Speed Test

    func testSpeed(nodes: [String]? = nil) {
        guard isRunning, let config else { return }
        isTestingSpeed = true
        let targetNodes = nodes ?? Array(config.proxies.keys)
        let port = self.port

        Task {
            await withTaskGroup(of: (String, Int?).self) { group in
                for name in targetNodes {
                    group.addTask {
                        let ms = await Self.measureNodeLatency(port: port)
                        return (name, ms)
                    }
                }
                for await (name, ms) in group {
                    self.nodeSpeeds[name] = ms ?? -1
                }
            }
            isTestingSpeed = false
            log("Speed test completed for \(targetNodes.count) nodes")
        }
    }

    private static func measureNodeLatency(port: UInt16) async -> Int? {
        let start = Date()
        let proxyDict: [String: Any] = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(port),
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: Int(port),
        ]
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = proxyDict
        sessionConfig.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: sessionConfig)
        do {
            let (_, response) = try await session.data(from: URL(string: "http://www.gstatic.com/generate_204")!)
            if let http = response as? HTTPURLResponse, http.statusCode == 204 {
                return Int(Date().timeIntervalSince(start) * 1000)
            }
            return nil
        } catch {
            return nil
        }
    }
}


import Foundation
import Network

/// Main proxy engine that ties together Inbound, Router, and Outbound
public final class ProxyEngine: @unchecked Sendable {
    private let config: AppConfig
    private let router: Router
    private let outbound: Outbound
    private var inbound: Inbound?
    private let listenPort: UInt16
    private var _isRunning = false

    public var isRunning: Bool { _isRunning }

    public init(config: AppConfig, port: UInt16 = 7890) {
        self.config = config
        self.listenPort = port

        // Build router with rules
        self.router = Router(rules: config.rules)

        // Build outbound with proxies and groups
        self.outbound = Outbound(proxies: config.proxies, groups: config.groups, dnsServer: config.general.dnsServer)
    }

    /// Initialize with expanded RULE-SET rules
    public init(config: AppConfig, port: UInt16 = 7890, expandedRuleSets: [String: [Rule]]) {
        self.config = config
        self.listenPort = port
        self.router = Router(rules: config.rules, expandedRuleSets: expandedRuleSets)
        self.outbound = Outbound(proxies: config.proxies, groups: config.groups, dnsServer: config.general.dnsServer)
    }

    public func start() throws {
        let inbound = try Inbound(port: listenPort) { [weak self] connection, request in
            self?.handleRequest(connection: connection, request: request)
        }
        inbound.start()
        self.inbound = inbound
        _isRunning = true
        splog.info("Started on port \(listenPort)", tag: "ProxyEngine")
    }

    public func stop() {
        inbound?.stop()
        inbound = nil
        _isRunning = false
        splog.info("Stopped", tag: "ProxyEngine")
    }

    public func select(group: String, node: String) {
        outbound.select(group: group, node: node)
    }

    public func status() -> EngineStatus {
        EngineStatus(
            isRunning: _isRunning,
            listenPort: listenPort,
            selectedNodes: outbound.getSelectedNodes()
        )
    }

    private func handleRequest(connection: NWConnection, request: Inbound.ProxyRequest) {
        let target = request.target
        let skipProxy = config.general.skipProxy

        // Check skip-proxy list
        for pattern in skipProxy {
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1)) // ".domain.com"
                if target.host.hasSuffix(suffix) || target.host == String(pattern.dropFirst(2)) {
                    outbound.relay(client: connection, target: target, policy: "DIRECT", initialData: request.initialData)
                    return
                }
            } else if target.host == pattern {
                outbound.relay(client: connection, target: target, policy: "DIRECT", initialData: request.initialData)
                return
            }
        }

        // Route through rules
        let policy = router.match(host: target.host)
        outbound.relay(client: connection, target: target, policy: policy, initialData: request.initialData)
    }
}

public struct EngineStatus: Sendable {
    public let isRunning: Bool
    public let listenPort: UInt16
    public let selectedNodes: [String: String]
}

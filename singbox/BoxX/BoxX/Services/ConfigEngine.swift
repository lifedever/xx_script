// BoxX/Services/ConfigEngine.swift
import Foundation
import Observation

// MARK: - GroupPattern

struct GroupPattern: Codable, Equatable, Sendable {
    var mode: String  // "keyword" or "regex"
    var patterns: [String]
}

private extension Notification.Name {
    static let configFileDidChange = Notification.Name("com.boxx.configFileDidChange")
}

@Observable
class ConfigEngine: @unchecked Sendable {
    var config: SingBoxConfig
    private(set) var proxies: [String: [Outbound]] = [:]  // key = subscription name

    let baseDir: URL
    private var configURL: URL { baseDir.appendingPathComponent("config.json") }
    private var proxiesDir: URL { baseDir.appendingPathComponent("proxies") }
    private var runtimeURL: URL { baseDir.appendingPathComponent("runtime-config.json") }
    private var lastMtime: Date?
    private var watcher: FileWatcher?
    private var watcherObserver: NSObjectProtocol?

    /// Called after deployRuntime writes runtime-config.json.
    var onDeployComplete: (() -> Void)?

    /// Describes the current proxy inbound configuration.
    struct ProxyInboundConfig {
        var isMixed: Bool       // true = mixed (HTTP+SOCKS share port), false = separate
        var mixedPort: Int
        var httpPort: Int
        var socksPort: Int

        var displayText: String {
            if isMixed {
                return "HTTP/SOCKS  127.0.0.1:\(mixedPort)"
            } else {
                return "HTTP  :\(httpPort)  |  SOCKS  :\(socksPort)"
            }
        }

        /// The port used for HTTP proxy (for env export, WakeObserver, etc.)
        var effectiveHTTPPort: Int { isMixed ? mixedPort : httpPort }
    }

    /// Read the current proxy inbound configuration.
    var proxyInbound: ProxyInboundConfig {
        var httpPort = 7890
        var socksPort = 7891
        var mixedPort = 7890
        var hasMixed = false
        var hasHTTP = false
        var hasSocks = false

        for inbound in config.inbounds {
            let type = inbound["type"]?.stringValue
            let port = inbound["listen_port"]?.numberValue.map { Int($0) } ?? 7890
            switch type {
            case "mixed": hasMixed = true; mixedPort = port
            case "http": hasHTTP = true; httpPort = port
            case "socks": hasSocks = true; socksPort = port
            default: break
            }
        }

        if hasMixed {
            return ProxyInboundConfig(isMixed: true, mixedPort: mixedPort, httpPort: mixedPort, socksPort: mixedPort)
        } else if hasHTTP || hasSocks {
            return ProxyInboundConfig(isMixed: false, mixedPort: httpPort, httpPort: httpPort, socksPort: socksPort)
        }
        return ProxyInboundConfig(isMixed: true, mixedPort: 7890, httpPort: 7890, socksPort: 7890)
    }

    /// The effective HTTP port (for env export, connectivity checks, etc.)
    var mixedPort: Int { proxyInbound.effectiveHTTPPort }

    /// Apply new proxy inbound configuration, replacing existing http/socks/mixed inbounds.
    func applyProxyInbound(_ newConfig: ProxyInboundConfig) {
        // Remove old proxy inbounds
        config.inbounds.removeAll {
            let t = $0["type"]?.stringValue
            return t == "mixed" || t == "http" || t == "socks"
        }

        if newConfig.isMixed {
            config.inbounds.insert(.object([
                "type": .string("mixed"),
                "tag": .string("mixed-in"),
                "listen": .string("127.0.0.1"),
                "listen_port": .number(Double(newConfig.mixedPort)),
            ]), at: 0)
        } else {
            config.inbounds.insert(contentsOf: [
                .object([
                    "type": .string("http"),
                    "tag": .string("http-in"),
                    "listen": .string("127.0.0.1"),
                    "listen_port": .number(Double(newConfig.httpPort)),
                ]),
                .object([
                    "type": .string("socks"),
                    "tag": .string("socks-in"),
                    "listen": .string("127.0.0.1"),
                    "listen_port": .number(Double(newConfig.socksPort)),
                ]),
            ], at: 0)
        }
    }

    init(baseDir: URL) {
        self.config = SingBoxConfig(inbounds: [], outbounds: [], route: RouteConfig())
        self.baseDir = baseDir
    }

    // MARK: - Load

    func load() throws {
        var data = try Data(contentsOf: configURL)
        // Migrate 🇹🇼 → 🇨🇳 in config
        let twFlag = "\u{1F1F9}\u{1F1FC}"
        let cnFlag = "\u{1F1E8}\u{1F1F3}"
        if var jsonString = String(data: data, encoding: .utf8), jsonString.contains(twFlag) {
            jsonString = jsonString.replacingOccurrences(of: twFlag, with: cnFlag)
            data = jsonString.data(using: .utf8) ?? data
            try data.write(to: configURL, options: .atomic)
        }
        config = try JSONDecoder().decode(SingBoxConfig.self, from: data)

        // Deduplicate outbound tags (can happen after 🇹🇼→🇨🇳 migration)
        var seenTags = Set<String>()
        config.outbounds.removeAll { ob in
            if seenTags.contains(ob.tag) { return true }
            seenTags.insert(ob.tag)
            return false
        }

        lastMtime = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date

        // Load proxy files
        proxies = [:]
        if FileManager.default.fileExists(atPath: proxiesDir.path) {
            let files = try FileManager.default.contentsOfDirectory(at: proxiesDir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                let name = file.deletingPathExtension().lastPathComponent
                let proxyData = try Data(contentsOf: file)
                let nodes = try JSONDecoder().decode([Outbound].self, from: proxyData)
                proxies[name] = nodes
            }
        }

        // Auto-fix group outbounds on load
        if fixGroupOutbounds() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(config) {
                try? data.write(to: configURL, options: .atomic)
            }
        }
    }

    // MARK: - Group Outbounds (Centralized)

    /// Layer classification for outbound groups (prevents circular dependencies)
    ///   Layer 0: DIRECT, proxy nodes
    ///   Layer 1: 📦subscription groups, region groups (🇭🇰等), 🌐其他 — only contain nodes
    ///   Layer 2: Proxy, 🐟漏网之鱼 — contain Layer 1 + Layer 0
    ///   Layer 3: Service selectors (OpenAI, Google etc.) — contain Layer 2 + Layer 1 + Layer 0

    /// All region group tags (from group-patterns.json + 🌐其他)
    var allRegionTags: [String] {
        loadGroupPatterns().keys.sorted() + (config.outbounds.contains(where: { $0.tag == "🌐其他" }) ? ["🌐其他"] : [])
    }

    /// All subscription group tags
    var allSubTags: [String] {
        config.outbounds.compactMap { $0.tag.hasPrefix("📦") ? $0.tag : nil }
    }

    /// Whether a tag is a Layer 1 group (subscription or region)
    func isLayer1Group(_ tag: String) -> Bool {
        tag.hasPrefix("📦") || Set(allRegionTags).contains(tag)
    }

    /// Whether a tag is a service selector (Layer 3)
    func isServiceSelector(_ tag: String) -> Bool {
        guard let ob = config.outbounds.first(where: { $0.tag == tag }) else { return false }
        switch ob {
        case .selector, .urltest: break
        default: return false
        }
        return tag != "Proxy" && tag != "DIRECT" && !tag.hasPrefix("📦") &&
               !tag.contains("漏网之鱼") && !Set(allRegionTags).contains(tag)
    }

    /// Build the standard outbounds list for a given group type
    func standardOutbounds(for tag: String) -> [String]? {
        let subs = allSubTags
        let regions = allRegionTags
        guard !subs.isEmpty || !regions.isEmpty else { return nil }

        if tag == "Proxy" {
            // Layer 2: subscriptions → regions → DIRECT
            var result: [String] = []
            for t in subs { result.append(t) }
            for t in regions { result.append(t) }
            result.append("DIRECT")
            return result
        }

        if tag.contains("漏网之鱼") {
            // Layer 2: Proxy → subscriptions → regions → DIRECT
            var result = ["Proxy"]
            for t in subs { result.append(t) }
            for t in regions { result.append(t) }
            result.append("DIRECT")
            return result
        }

        if isServiceSelector(tag) {
            // Layer 3: Proxy → DIRECT → subscriptions → regions
            var result = ["Proxy", "DIRECT"]
            for t in subs { result.append(t) }
            for t in regions { result.append(t) }
            return result
        }

        return nil  // Layer 1 groups (subscriptions, regions) — managed by subscription update
    }

    /// Fix all group outbounds to match the standard hierarchy. Returns true if anything changed.
    @discardableResult
    func fixGroupOutbounds() -> Bool {
        let subs = allSubTags
        let regions = allRegionTags
        guard !subs.isEmpty || !regions.isEmpty else { return false }
        var changed = false

        for i in config.outbounds.indices {
            let tag = config.outbounds[i].tag
            guard let expected = standardOutbounds(for: tag) else { continue }

            switch config.outbounds[i] {
            case .selector(var s):
                if s.outbounds != expected {
                    s.outbounds = expected
                    if let d = s.default, !expected.contains(d) { s.default = nil }
                    config.outbounds[i] = .selector(s)
                    changed = true
                }
            case .urltest(var u):
                // urltest doesn't get standard outbounds (it's auto-managed)
                break
            default: break
            }
        }
        return changed
    }

    // MARK: - Save

    func save(restartRequired: Bool = true) throws {
        // Clean up invalid default references before saving
        // default must be a member of the selector's own outbounds list
        for i in config.outbounds.indices {
            if case .selector(var s) = config.outbounds[i],
               let d = s.default, !s.outbounds.contains(d) {
                s.default = nil
                config.outbounds[i] = .selector(s)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
        lastMtime = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date

        // Auto-deploy runtime config when structure changes (skip node validation for speed)
        if restartRequired {
            try? deployRuntime(skipValidation: true)
        }
    }

    // MARK: - Reset

    /// Reset user content (subscriptions, proxy nodes, user-added rules, group settings).
    /// Keeps system defaults: DNS, inbounds, log, ntp, experimental, rule_set rules, service selectors.
    func resetUserContent() throws {
        let fm = FileManager.default

        // 1. Replace config.json with bundled default template
        guard let defaultURL = Bundle.main.url(forResource: "default-config", withExtension: "json"),
              let defaultData = try? Data(contentsOf: defaultURL) else {
            throw NSError(domain: "BoxX", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到默认配置模板"])
        }
        try defaultData.write(to: configURL, options: .atomic)

        // 2. Clear subscriptions
        let subsURL = baseDir.appendingPathComponent("subscriptions.json")
        try? "[]".data(using: .utf8)?.write(to: subsURL, options: .atomic)

        // 3. Clear proxies directory
        if fm.fileExists(atPath: proxiesDir.path) {
            let files = try fm.contentsOfDirectory(at: proxiesDir, includingPropertiesForKeys: nil)
            for file in files { try? fm.removeItem(at: file) }
        }

        // 4. Clear group patterns and order
        try? fm.removeItem(at: groupPatternsURL)
        try? fm.removeItem(at: groupOrderURL)

        // 5. Clear cache
        let cacheURL = baseDir.appendingPathComponent("cache.db")
        try? fm.removeItem(at: cacheURL)

        // 6. Reload clean config into memory
        proxies = [:]
        try load()

        // 7. Regenerate runtime-config.json so RuleOverviewView shows clean data
        try? deployRuntime(skipValidation: true)
    }

    // MARK: - Merge & Deploy

    func buildRuntimeConfig() -> SingBoxConfig {
        var runtime = config

        let ud = UserDefaults.standard

        // Remove TUN inbound when disabled in settings (default: enabled)
        let tunEnabled = ud.object(forKey: "tunEnabled") as? Bool ?? true
        if !tunEnabled {
            runtime.inbounds.removeAll { $0["type"]?.stringValue == "tun" }
            runtime.route.unknownFields.removeValue(forKey: "auto_detect_interface")
        }

        // Apply advanced network settings to TUN inbound
        if tunEnabled {
            for i in runtime.inbounds.indices where runtime.inbounds[i]["type"]?.stringValue == "tun" {
                guard case .object(var tunDict) = runtime.inbounds[i] else { continue }
                // Endpoint Independent NAT
                if ud.bool(forKey: "endpointIndependentNAT") {
                    tunDict["endpoint_independent_nat"] = .bool(true)
                }
                // TUN exclude addresses
                let excludeStr = ud.string(forKey: "tunExcludeAddresses") ?? ""
                let excludeAddrs = excludeStr.components(separatedBy: CharacterSet.newlines.union(.init(charactersIn: ",")))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !excludeAddrs.isEmpty {
                    tunDict["route_exclude_address"] = .array(excludeAddrs.map { .string($0) })
                }
                runtime.inbounds[i] = .object(tunDict)
            }
        }

        // Apply direct DNS server setting
        let directDNS = ud.string(forKey: "directDNS") ?? "udp://223.5.5.5"
        if var dns = runtime.dns, var servers = dns.servers {
            for i in servers.indices where servers[i]["tag"]?.stringValue == "dns_direct" {
                var dict: [String: JSONValue] = ["tag": .string("dns_direct")]
                if directDNS == "local" {
                    dict["type"] = .string("local")
                } else if directDNS.hasPrefix("doh-ip://") {
                    // DoH via IP address (e.g. "doh-ip://223.5.5.5" → HTTPS to 223.5.5.5)
                    let ip = directDNS.replacingOccurrences(of: "doh-ip://", with: "")
                    let sni = Self.sniForIP(ip)
                    dict["type"] = .string("https")
                    dict["server"] = .string(ip)
                    if !sni.isEmpty { dict["tls"] = .object(["server_name": .string(sni)]) }
                } else if directDNS.hasPrefix("doq://") {
                    // DoQ via IP address (e.g. "doq://223.5.5.5" → QUIC to 223.5.5.5)
                    let ip = directDNS.replacingOccurrences(of: "doq://", with: "")
                    let sni = Self.sniForIP(ip)
                    dict["type"] = .string("quic")
                    dict["server"] = .string(ip)
                    if !sni.isEmpty {
                        dict["tls"] = .object(["server_name": .string(sni)])
                    }
                } else {
                    // UDP (e.g. "udp://223.5.5.5")
                    dict["type"] = .string("udp")
                    dict["server"] = .string(directDNS.replacingOccurrences(of: "udp://", with: ""))
                }
                servers[i] = .object(dict)
            }
            // Apply proxy DNS server setting
            let proxyDNSType = ud.string(forKey: "proxyDNS") ?? "tcp"
            for i in servers.indices where servers[i]["tag"]?.stringValue == "dns_proxy" {
                if case .object(var dict) = servers[i] {
                    dict["type"] = .string(proxyDNSType)
                    servers[i] = .object(dict)
                }
            }

            dns.servers = servers

            // Apply DNS cache capacity
            let cacheCapacity = ud.integer(forKey: "dnsCacheCapacity")
            if cacheCapacity > 0 {
                dns.unknownFields["cache_capacity"] = .number(Double(cacheCapacity))
            }
            runtime.dns = dns
        }

        // Deduplicate proxy nodes across subscriptions (same tag = keep first)
        let existingTags = Set(runtime.outbounds.map { $0.tag })
        var seenTags = existingTags
        let allProxyNodes = proxies.values.flatMap { $0 }.filter { seenTags.insert($0.tag).inserted }
        runtime.outbounds.append(contentsOf: allProxyNodes)

        // Enable TCP Fast Open on all proxy outbounds
        for i in runtime.outbounds.indices where runtime.outbounds[i].isProxyNode {
            runtime.outbounds[i].tcpFastOpen = true
        }

        // Convert remote rule sets to local when the file has been downloaded by BoxX.
        // This ensures sing-box reads from disk (not its own cache.db), so rule set
        // updates via the "update" button take effect immediately on reload.
        let rulesDir = baseDir.appendingPathComponent("rules")
        if var ruleSets = runtime.route.ruleSet {
            for i in ruleSets.indices {
                guard case .object(var dict) = ruleSets[i],
                      dict["type"]?.stringValue == "remote",
                      let tag = dict["tag"]?.stringValue else { continue }
                let format = dict["format"]?.stringValue ?? "binary"
                let ext = format == "binary" ? "srs" : "json"
                let localFile = rulesDir.appendingPathComponent("\(tag).\(ext)")
                if FileManager.default.fileExists(atPath: localFile.path) {
                    // Rewrite as local rule set pointing to the downloaded file
                    dict["type"] = .string("local")
                    dict["path"] = .string(localFile.path)
                    dict.removeValue(forKey: "url")
                    dict.removeValue(forKey: "download_detour")
                    dict.removeValue(forKey: "update_interval")
                    ruleSets[i] = .object(dict)
                }
            }
            runtime.route.ruleSet = ruleSets
        }

        // Enable process detection for monitoring
        runtime.route.unknownFields["find_process"] = .bool(true)

        // sing-box 1.12+ requires default_domain_resolver in route (preserve existing, fallback to dns_direct)
        if runtime.route.unknownFields["default_domain_resolver"] == nil {
            runtime.route.unknownFields["default_domain_resolver"] = .string("dns_direct")
        }

        // Inject block-custom rule set if file exists and is non-empty
        let blockFile = baseDir.appendingPathComponent("rules/block-custom.json")
        if FileManager.default.fileExists(atPath: blockFile.path),
           let blockData = try? Data(contentsOf: blockFile),
           let blockJSON = try? JSONSerialization.jsonObject(with: blockData) as? [String: Any],
           let blockRules = blockJSON["rules"] as? [[String: Any]], !blockRules.isEmpty {
            // Add local rule_set definition
            let ruleSetEntry: JSONValue = .object([
                "type": .string("local"),
                "tag": .string("block-custom"),
                "format": .string("source"),
                "path": .string(blockFile.path),
            ])
            var ruleSets = runtime.route.ruleSet ?? []
            if !ruleSets.contains(where: { $0["tag"]?.stringValue == "block-custom" }) {
                ruleSets.append(ruleSetEntry)
                runtime.route.ruleSet = ruleSets
            }
            // Add reject rule at the front of route.rules (after system rules)
            var rules = runtime.route.rules ?? []
            if !rules.contains(where: {
                $0["rule_set"]?.arrayValue?.contains(where: { $0.stringValue == "block-custom" }) == true
            }) {
                let rejectRule: JSONValue = .object([
                    "rule_set": .array([.string("block-custom")]),
                    "action": .string("reject"),
                ])
                // Insert after system rules (sniff, hijack-dns, ip_is_private, clash_mode)
                let systemActions: Set<String> = ["sniff", "hijack-dns", "reject"]
                var insertIdx = 0
                for rule in rules {
                    let action = rule["action"]?.stringValue ?? ""
                    let isSystem = rule["ip_is_private"] != nil || rule["clash_mode"] != nil ||
                                   rule["rules"] != nil || systemActions.contains(action)
                    guard isSystem else { break }
                    insertIdx += 1
                }
                rules.insert(rejectRule, at: insertIdx)
                runtime.route.rules = rules
            }
        }

        // Inject urltest settings from UserDefaults
        let testURL = ud.string(forKey: "speedTestURL") ?? "http://1.1.1.1/generate_204"
        let testInterval = ud.string(forKey: "urlTestInterval").flatMap({ $0.isEmpty ? nil : $0 }) ?? "3m"
        let testTolerance = ud.integer(forKey: "urlTestTolerance")
        let toleranceValue = testTolerance > 0 ? testTolerance : 50

        // Validate: remove references to non-existent outbounds from selectors/urltest
        let allTags = Set(runtime.outbounds.map { $0.tag })
        for i in runtime.outbounds.indices {
            switch runtime.outbounds[i] {
            case .selector(var s):
                s.outbounds = s.outbounds.filter { allTags.contains($0) }
                if s.outbounds.isEmpty { s.outbounds = ["DIRECT"] }
                if let d = s.default, !s.outbounds.contains(d) { s.default = nil }
                s.unknownFields["interrupt_exist_connections"] = .bool(true)
                runtime.outbounds[i] = .selector(s)
            case .urltest(var u):
                let before = u.outbounds.count
                u.outbounds = u.outbounds.filter { allTags.contains($0) }
                if u.outbounds.isEmpty { u.outbounds = ["DIRECT"] }
                u.url = testURL
                u.interval = testInterval
                u.tolerance = toleranceValue
                u.unknownFields["interrupt_exist_connections"] = .bool(true)
                runtime.outbounds[i] = .urltest(u)
            default: break
            }
        }

        return runtime
    }

    func deployRuntime(skipValidation: Bool = false) throws {
        // cache.db is deleted by the launcher script (runs as root)
        // No need to delete here — can't sudo rm paths with spaces in sudoers

        var runtime = buildRuntimeConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(runtime)
        // Ensure no 🇹🇼 in runtime config
        if var jsonString = String(data: data, encoding: .utf8),
           jsonString.contains("\u{1F1F9}\u{1F1FC}") {
            jsonString = jsonString.replacingOccurrences(of: "\u{1F1F9}\u{1F1FC}", with: "\u{1F1E8}\u{1F1F3}")
            data = jsonString.data(using: .utf8) ?? data
        }
        try data.write(to: runtimeURL, options: .atomic)

        // Skip validation when only rules/outbound changes (not node changes)
        if skipValidation {
            onDeployComplete?()
            return
        }

        // Validate config with sing-box check. If it fails, try removing problematic proxy nodes.
        if !validateConfig() {
            print("[BoxX] Config validation failed, trying to remove problematic nodes...")
            // Remove proxy nodes (keep selectors/urltest/direct) and re-add one by one
            let proxyTypes: Set<String> = ["vmess", "shadowsocks", "trojan", "hysteria2", "vless"]
            let coreOutbounds = runtime.outbounds.filter { ob in
                switch ob {
                case .selector, .urltest, .direct: return true
                case .unknown(_, let type, _): return !proxyTypes.contains(type)
                default: return false
                }
            }
            let proxyOutbounds = runtime.outbounds.filter { ob in
                switch ob {
                case .vmess, .shadowsocks, .trojan, .hysteria2, .vless: return true
                case .unknown(_, let type, _): return proxyTypes.contains(type)
                default: return false
                }
            }

            // Try adding each proxy node, skip ones that cause validation failure
            var validProxies: [Outbound] = []
            for proxy in proxyOutbounds {
                runtime.outbounds = coreOutbounds + validProxies + [proxy]
                // Re-validate selectors
                let allTags = Set(runtime.outbounds.map { $0.tag })
                for i in runtime.outbounds.indices {
                    switch runtime.outbounds[i] {
                    case .selector(var s):
                        s.outbounds = s.outbounds.filter { allTags.contains($0) }
                        if s.outbounds.isEmpty { s.outbounds = ["DIRECT"] }
                        if let d = s.default, !s.outbounds.contains(d) { s.default = nil }
                        runtime.outbounds[i] = .selector(s)
                    case .urltest(var u):
                        u.outbounds = u.outbounds.filter { allTags.contains($0) }
                        if u.outbounds.isEmpty { u.outbounds = ["DIRECT"] }
                        runtime.outbounds[i] = .urltest(u)
                    default: break
                    }
                }
                data = try encoder.encode(runtime)
                try data.write(to: runtimeURL, options: .atomic)
                if validateConfig() {
                    validProxies.append(proxy)
                } else {
                    print("[BoxX] Skipping problematic node: \(proxy.tag)")
                }
            }
            // Write final valid config
            runtime.outbounds = coreOutbounds + validProxies
            let finalAllTags = Set(runtime.outbounds.map { $0.tag })
            for i in runtime.outbounds.indices {
                switch runtime.outbounds[i] {
                case .selector(var s):
                    s.outbounds = s.outbounds.filter { finalAllTags.contains($0) }
                    if s.outbounds.isEmpty { s.outbounds = ["DIRECT"] }
                    if let d = s.default, !finalAllTags.contains(d) { s.default = nil }
                    runtime.outbounds[i] = .selector(s)
                case .urltest(var u):
                    u.outbounds = u.outbounds.filter { finalAllTags.contains($0) }
                    if u.outbounds.isEmpty { u.outbounds = ["DIRECT"] }
                    runtime.outbounds[i] = .urltest(u)
                default: break
                }
            }
            data = try encoder.encode(runtime)
            try data.write(to: runtimeURL, options: .atomic)
            print("[BoxX] Deployed with \(validProxies.count)/\(proxyOutbounds.count) valid proxy nodes")
        }
        onDeployComplete?()
    }

    // MARK: - Proxy File Management

    func saveProxies(name: String, nodes: [Outbound]) throws {
        try FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(nodes)
        // Replace 🇹🇼 with 🇨🇳 in node names
        if var jsonString = String(data: data, encoding: .utf8) {
            jsonString = jsonString.replacingOccurrences(of: "\u{1F1F9}\u{1F1FC}", with: "\u{1F1E8}\u{1F1F3}")
            data = jsonString.data(using: .utf8) ?? data
        }
        try data.write(to: proxiesDir.appendingPathComponent("\(name).json"), options: .atomic)
        // Reload replaced nodes
        proxies[name] = try JSONDecoder().decode([Outbound].self, from: data)
    }

    func removeProxies(name: String) throws {
        let file = proxiesDir.appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        proxies.removeValue(forKey: name)
    }

    // MARK: - Validation

    /// Run `sing-box check` to validate the runtime config
    private func validateConfig() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")
        proc.arguments = ["check", "-c", runtimeURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: - File Watching

    func startWatching() {
        let watchDir = configURL.deletingLastPathComponent().path
        watcher = FileWatcher(path: watchDir) { @Sendable in
            NotificationCenter.default.post(name: .configFileDidChange, object: nil)
        }
        watcher?.start()

        watcherObserver = NotificationCenter.default.addObserver(
            forName: .configFileDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            try? self?.load()
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        if let observer = watcherObserver {
            NotificationCenter.default.removeObserver(observer)
            watcherObserver = nil
        }
    }

    // MARK: - Group Patterns

    private var groupPatternsURL: URL { baseDir.appendingPathComponent("group-patterns.json") }

    func loadGroupPatterns() -> [String: GroupPattern] {
        guard let data = try? Data(contentsOf: groupPatternsURL) else { return [:] }
        // Replace 🇹🇼 with 🇨🇳 in group pattern keys
        var patterns = (try? JSONDecoder().decode([String: GroupPattern].self, from: data)) ?? [:]
        let twFlag = "\u{1F1F9}\u{1F1FC}"
        let cnFlag = "\u{1F1E8}\u{1F1F3}"
        let keysToFix = patterns.keys.filter { $0.contains(twFlag) }
        for key in keysToFix {
            if let value = patterns.removeValue(forKey: key) {
                patterns[key.replacingOccurrences(of: twFlag, with: cnFlag)] = value
            }
        }
        if !keysToFix.isEmpty { saveGroupPatterns(patterns) }
        return patterns
    }

    func saveGroupPatterns(_ patterns: [String: GroupPattern]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(patterns) else { return }
        try? data.write(to: groupPatternsURL, options: .atomic)
    }

    private var groupOrderURL: URL { baseDir.appendingPathComponent("group-order.json") }

    func loadGroupOrder() -> [String] {
        guard let data = try? Data(contentsOf: groupOrderURL) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func saveGroupOrder(_ order: [String]) {
        guard let data = try? JSONEncoder().encode(order) else { return }
        try? data.write(to: groupOrderURL, options: .atomic)
    }

    /// Load patterns with stable ordering
    func loadOrderedGroupKeys() -> [String] {
        let patterns = loadGroupPatterns()
        let savedOrder = loadGroupOrder()
        // Use saved order, append any new keys not in saved order
        var result = savedOrder.filter { patterns.keys.contains($0) }
        for key in patterns.keys.sorted() where !result.contains(key) {
            result.append(key)
        }
        return result
    }

    // MARK: - Rename Group

    /// Rename a strategy group tag across all config references.
    func renameGroup(oldTag: String, newTag: String) {
        // 1. Update the outbound's own tag
        for i in config.outbounds.indices {
            if config.outbounds[i].tag == oldTag {
                switch config.outbounds[i] {
                case .selector(var s):
                    s.tag = newTag
                    config.outbounds[i] = .selector(s)
                case .urltest(var u):
                    u.tag = newTag
                    config.outbounds[i] = .urltest(u)
                default:
                    break
                }
            }
        }

        // 2. Update references in other selector/urltest outbounds lists
        for i in config.outbounds.indices {
            switch config.outbounds[i] {
            case .selector(var s):
                if let idx = s.outbounds.firstIndex(of: oldTag) {
                    s.outbounds[idx] = newTag
                    config.outbounds[i] = .selector(s)
                }
                if s.default == oldTag {
                    s.default = newTag
                    config.outbounds[i] = .selector(s)
                }
            case .urltest(var u):
                if let idx = u.outbounds.firstIndex(of: oldTag) {
                    u.outbounds[idx] = newTag
                    config.outbounds[i] = .urltest(u)
                }
            default:
                break
            }
        }

        // 3. Update route.rules outbound references
        if var rules = config.route.rules {
            for i in rules.indices {
                if case .object(var dict) = rules[i],
                   case .string(let outbound) = dict["outbound"],
                   outbound == oldTag {
                    dict["outbound"] = .string(newTag)
                    rules[i] = .object(dict)
                }
            }
            config.route.rules = rules
        }

        // 4. Update route.final if it references oldTag
        if config.route.final_ == oldTag {
            config.route.final_ = newTag
        }

        // 5. Rename key in group-patterns.json
        var patterns = loadGroupPatterns()
        if let pattern = patterns.removeValue(forKey: oldTag) {
            patterns[newTag] = pattern
            saveGroupPatterns(patterns)
        }
    }

    // MARK: - DNS Helpers

    /// Map DNS server IP to its TLS SNI domain for certificate validation
    static func sniForIP(_ ip: String) -> String {
        switch ip {
        case "223.5.5.5", "223.6.6.6": return "dns.alidns.com"
        case "1.12.12.12", "120.53.53.53": return "dot.pub"
        default: return ""
        }
    }
}

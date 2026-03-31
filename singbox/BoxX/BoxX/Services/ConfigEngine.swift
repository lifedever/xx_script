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
    }

    // MARK: - Merge & Deploy

    func buildRuntimeConfig() -> SingBoxConfig {
        var runtime = config
        // Deduplicate proxy nodes across subscriptions (same tag = keep first)
        let existingTags = Set(runtime.outbounds.map { $0.tag })
        var seenTags = existingTags
        let allProxyNodes = proxies.values.flatMap { $0 }.filter { seenTags.insert($0.tag).inserted }
        runtime.outbounds.append(contentsOf: allProxyNodes)

        // Enable process detection for monitoring
        runtime.route.unknownFields["find_process"] = .bool(true)

        // Inject urltest settings from UserDefaults
        let ud = UserDefaults.standard
        let testURL = ud.string(forKey: "speedTestURL") ?? "http://cp.cloudflare.com/generate_204"
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
                // Clear default if it references a non-existent outbound
                if let d = s.default, !s.outbounds.contains(d) { s.default = nil }
                runtime.outbounds[i] = .selector(s)
            case .urltest(var u):
                let before = u.outbounds.count
                u.outbounds = u.outbounds.filter { allTags.contains($0) }
                if u.outbounds.isEmpty { u.outbounds = ["DIRECT"] }
                u.url = testURL
                u.interval = testInterval
                u.tolerance = toleranceValue
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
}

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
    }

    // MARK: - Save

    func save(restartRequired: Bool = true) throws {
        // Mtime conflict check: if file was externally modified since last load, reload first
        if let currentMtime = try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date,
           let lastMtime, currentMtime > lastMtime {
            try load()  // Reload external changes
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

    // MARK: - Merge & Deploy

    func buildRuntimeConfig() -> SingBoxConfig {
        var runtime = config
        let allProxyNodes = proxies.values.flatMap { $0 }
        runtime.outbounds.append(contentsOf: allProxyNodes)

        // Validate: remove references to non-existent outbounds from selectors/urltest
        let allTags = Set(runtime.outbounds.map { $0.tag })
        for i in runtime.outbounds.indices {
            switch runtime.outbounds[i] {
            case .selector(var s):
                let before = s.outbounds.count
                s.outbounds = s.outbounds.filter { allTags.contains($0) }
                if s.outbounds.isEmpty { s.outbounds = ["DIRECT"] }
                if s.outbounds.count != before {
                    runtime.outbounds[i] = .selector(s)
                }
            case .urltest(var u):
                let before = u.outbounds.count
                u.outbounds = u.outbounds.filter { allTags.contains($0) }
                if u.outbounds.isEmpty { u.outbounds = ["DIRECT"] }
                if u.outbounds.count != before {
                    runtime.outbounds[i] = .urltest(u)
                }
            default: break
            }
        }

        return runtime
    }

    func deployRuntime(skipValidation: Bool = false) throws {
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

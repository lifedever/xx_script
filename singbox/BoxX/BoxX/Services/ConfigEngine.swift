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
    /// App sets this to restart sing-box via SingBoxProcess.
    var onDeployComplete: (() throws -> Void)?

    init(baseDir: URL) {
        self.config = SingBoxConfig(inbounds: [], outbounds: [], route: RouteConfig())
        self.baseDir = baseDir
    }

    // MARK: - Load

    func load() throws {
        let data = try Data(contentsOf: configURL)
        config = try JSONDecoder().decode(SingBoxConfig.self, from: data)
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

        // Auto-deploy runtime config and restart sing-box when structure changes
        if restartRequired {
            try? deployRuntime()
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

    func deployRuntime() throws {
        let runtime = buildRuntimeConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(runtime)
        try data.write(to: runtimeURL, options: .atomic)
        try onDeployComplete?()
    }

    // MARK: - Proxy File Management

    func saveProxies(name: String, nodes: [Outbound]) throws {
        try FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(nodes)
        try data.write(to: proxiesDir.appendingPathComponent("\(name).json"), options: .atomic)
        proxies[name] = nodes
    }

    func removeProxies(name: String) throws {
        let file = proxiesDir.appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        proxies.removeValue(forKey: name)
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
        return (try? JSONDecoder().decode([String: GroupPattern].self, from: data)) ?? [:]
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

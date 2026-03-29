// BoxX/Services/ConfigEngine.swift
import Foundation
import Observation

private extension Notification.Name {
    static let configFileDidChange = Notification.Name("com.boxx.configFileDidChange")
}

@Observable
class ConfigEngine {
    private(set) var config: SingBoxConfig
    private(set) var proxies: [String: [Outbound]] = [:]  // key = subscription name

    let baseDir: URL
    private var configURL: URL { baseDir.appendingPathComponent("config.json") }
    private var proxiesDir: URL { baseDir.appendingPathComponent("proxies") }
    private var runtimeURL: URL { baseDir.appendingPathComponent("runtime-config.json") }
    private var lastMtime: Date?
    private var watcher: FileWatcher?
    private var watcherObserver: NSObjectProtocol?

    /// Called after deployRuntime writes runtime-config.json.
    /// App sets this to call XPCClient.reload().
    var onDeployComplete: (() async -> Void)?

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

    func save() throws {
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
    }

    // MARK: - Merge & Deploy

    func buildRuntimeConfig() -> SingBoxConfig {
        var runtime = config
        let allProxyNodes = proxies.values.flatMap { $0 }
        runtime.outbounds.append(contentsOf: allProxyNodes)
        return runtime
    }

    func deployRuntime() async throws {
        let runtime = buildRuntimeConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(runtime)
        try data.write(to: runtimeURL, options: .atomic)
        await onDeployComplete?()
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
}

import Foundation

// MARK: - Subscription Info

public struct SubscriptionInfo: Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var url: String
    public var lastUpdate: Date?
    public var nodeCount: Int
    public var autoRefreshHours: Int

    public init(name: String, url: String, autoRefreshHours: Int = 24) {
        self.id = UUID().uuidString
        self.name = name
        self.url = url
        self.lastUpdate = nil
        self.nodeCount = 0
        self.autoRefreshHours = autoRefreshHours
    }
}

// MARK: - Subscription Manager

public final class SubscriptionManager: @unchecked Sendable {
    private let baseDir: String
    private let nodesDir: String
    private let metaPath: String

    public init(baseDir: String = NSHomeDirectory() + "/.shadowproxy/subscriptions") {
        self.baseDir = baseDir
        self.nodesDir = baseDir + "/nodes"
        self.metaPath = baseDir + "/subscriptions.json"
        try? FileManager.default.createDirectory(
            atPath: nodesDir, withIntermediateDirectories: true
        )
    }

    // MARK: CRUD

    public func add(name: String, url: String) async throws {
        var info = SubscriptionInfo(name: name, url: url)
        let nodes = try await fetchAndParse(url: url)
        info.nodeCount = nodes.count
        info.lastUpdate = Date()
        var subs = loadMeta()
        subs.append(info)
        saveMeta(subs)
        splog.info("Added subscription '\(name)' with \(nodes.count) nodes", tag: "Sub")
    }

    public func refresh(id: String) async throws {
        var subs = loadMeta()
        guard let idx = subs.firstIndex(where: { $0.id == id }) else { return }
        let nodes = try await fetchAndParse(url: subs[idx].url)
        subs[idx].nodeCount = nodes.count
        subs[idx].lastUpdate = Date()
        saveMeta(subs)
        splog.info("Refreshed '\(subs[idx].name)': \(nodes.count) nodes", tag: "Sub")
    }

    public func refreshAll() async throws {
        for sub in loadMeta() {
            try await refresh(id: sub.id)
        }
    }

    public func delete(id: String) {
        var subs = loadMeta()
        subs.removeAll { $0.id == id }
        saveMeta(subs)
        try? FileManager.default.removeItem(atPath: nodesDir + "/\(id).json")
    }

    public func subscriptions() -> [SubscriptionInfo] {
        loadMeta()
    }

    public func allNodes() -> [String: ServerConfig] {
        // Placeholder — full serialization in future task
        [:]
    }

    // MARK: Internal

    private func fetchAndParse(url: String) async throws -> [ParsedNode] {
        guard let requestURL = URL(string: url) else {
            throw SubscriptionError.fetchFailed
        }
        let (data, _) = try await URLSession.shared.data(from: requestURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw SubscriptionError.fetchFailed
        }
        return try SubscriptionParser.parseSubscription(content)
    }

    // MARK: Persistence

    private func loadMeta() -> [SubscriptionInfo] {
        guard let data = FileManager.default.contents(atPath: metaPath),
              let subs = try? JSONDecoder().decode([SubscriptionInfo].self, from: data) else {
            return []
        }
        return subs
    }

    private func saveMeta(_ subs: [SubscriptionInfo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(subs) else { return }
        FileManager.default.createFile(atPath: metaPath, contents: data)
    }
}

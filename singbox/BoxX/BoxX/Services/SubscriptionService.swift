// BoxX/Services/SubscriptionService.swift
import Foundation

class SubscriptionService: @unchecked Sendable {
    let configEngine: ConfigEngine
    let fetcher = SubscriptionFetcher()
    private let parsers: [any ProxyParser] = [SingBoxJSONParser(), ClashYAMLParser()]
    let grouper = AutoGrouper()

    init(configEngine: ConfigEngine) {
        self.configEngine = configEngine
    }

    /// Fetch, parse, save, and deploy a subscription.
    /// Returns the number of nodes parsed.
    func updateSubscription(name: String, url: URL) async throws -> Int {
        // 1. Fetch
        let data = try await fetcher.fetch(url: url)

        // 2. Parse (try each parser)
        guard let parser = parsers.first(where: { $0.canParse(data) }) else {
            throw SubscriptionServiceError.unsupportedFormat
        }
        let nodes = try parser.parse(data)

        // 3. Convert ParsedProxy -> [Outbound]
        let outbounds = nodes.map { $0.toOutbound() }

        // 4. Save to proxies/{name}.json
        try configEngine.saveProxies(name: name, nodes: outbounds)

        // 5. Auto-group and update selector references in config
        let regionGroups = grouper.groupByRegion(outbounds)
        updateSelectorGroups(
            regionGroups: regionGroups,
            subscriptionName: name,
            nodeTags: outbounds.map { $0.tag }
        )

        // 6. Save config and deploy
        try configEngine.save()
        try await configEngine.deployRuntime()

        return nodes.count
    }

    /// Update all subscriptions.
    func updateAll(subscriptions: [(name: String, url: URL)]) async throws -> [String: Result<Int, Error>] {
        var results: [String: Result<Int, Error>] = [:]
        for sub in subscriptions {
            do {
                let count = try await updateSubscription(name: sub.name, url: sub.url)
                results[sub.name] = .success(count)
            } catch {
                results[sub.name] = .failure(error)
            }
        }
        return results
    }

    // MARK: - Private

    /// Ensure region-based selector groups exist in config and contain the right node tags.
    private func updateSelectorGroups(regionGroups: [String: [String]], subscriptionName: String, nodeTags: [String]) {
        // Add subscription group selector
        let subGroupTag = "📦\(subscriptionName)"
        ensureSelectorExists(tag: subGroupTag, nodeTags: nodeTags)

        // Add/update region group selectors
        for (regionName, tags) in regionGroups {
            ensureSelectorExists(tag: regionName, nodeTags: tags)
        }
    }

    private func ensureSelectorExists(tag: String, nodeTags: [String]) {
        if let index = configEngine.config.outbounds.firstIndex(where: { $0.tag == tag }) {
            // Update existing selector's outbounds
            if case .selector(var selector) = configEngine.config.outbounds[index] {
                for nodeTag in nodeTags {
                    if !selector.outbounds.contains(nodeTag) {
                        selector.outbounds.append(nodeTag)
                    }
                }
                configEngine.config.outbounds[index] = .selector(selector)
            }
        } else {
            // Create new selector
            let selector = SelectorOutbound(tag: tag, outbounds: nodeTags)
            configEngine.config.outbounds.append(.selector(selector))
        }
    }
}

enum SubscriptionServiceError: Error, LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Unsupported subscription format"
        }
    }
}

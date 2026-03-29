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
    /// Returns the number of nodes parsed and optional subscription info (traffic/expiry).
    func updateSubscription(name: String, url: URL) async throws -> (nodeCount: Int, info: SubscriptionInfo?) {
        // 1. Fetch
        let result = try await fetcher.fetch(url: url)

        // 2. Parse (try each parser)
        guard let parser = parsers.first(where: { $0.canParse(result.data) }) else {
            throw SubscriptionServiceError.unsupportedFormat
        }
        let nodes = try parser.parse(result.data)

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

        return (nodes.count, result.info)
    }

    /// Update all subscriptions.
    func updateAll(subscriptions: [(name: String, url: URL)]) async throws -> [String: Result<(nodeCount: Int, info: SubscriptionInfo?), Error>] {
        var results: [String: Result<(nodeCount: Int, info: SubscriptionInfo?), Error>] = [:]
        for sub in subscriptions {
            do {
                let result = try await updateSubscription(name: sub.name, url: sub.url)
                results[sub.name] = .success(result)
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

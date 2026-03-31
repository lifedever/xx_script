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
        var patterns = configEngine.loadGroupPatterns()
        if patterns.isEmpty {
            patterns = grouper.defaultPatterns()
            configEngine.saveGroupPatterns(patterns)
        }
        let regionGroups = grouper.groupByPatterns(outbounds, patterns: patterns)
        updateSelectorGroups(
            regionGroups: regionGroups,
            subscriptionName: name,
            nodeTags: outbounds.map { $0.tag }
        )

        // 6. Save config and deploy (skip per-node validation for speed)
        try configEngine.save(restartRequired: false)
        try configEngine.deployRuntime(skipValidation: true)

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

    /// Re-group existing nodes using current group-patterns (no network fetch needed)
    func regroupExistingNodes() throws {
        let patterns = configEngine.loadGroupPatterns()
        guard !patterns.isEmpty else { return }

        // Collect all proxy nodes from loaded proxies
        let allProxies = configEngine.proxies
        for (subName, nodes) in allProxies {
            let regionGroups = grouper.groupByPatterns(nodes, patterns: patterns)
            updateSelectorGroups(
                regionGroups: regionGroups,
                subscriptionName: subName,
                nodeTags: nodes.map { $0.tag }
            )
        }

        try configEngine.save(restartRequired: false)
        try configEngine.deployRuntime(skipValidation: true)
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

        // Update Proxy: add subscription group + all region groups
        if let proxyIdx = configEngine.config.outbounds.firstIndex(where: { $0.tag == "Proxy" }) {
            if case .selector(var proxy) = configEngine.config.outbounds[proxyIdx] {
                // Add subscription group
                if !proxy.outbounds.contains(subGroupTag) {
                    proxy.outbounds.insert(subGroupTag, at: proxy.outbounds.startIndex)
                }
                // Add region groups
                for regionName in regionGroups.keys.sorted() {
                    if !proxy.outbounds.contains(regionName) {
                        proxy.outbounds.append(regionName)
                    }
                }
                // Keep DIRECT at the end
                if let i = proxy.outbounds.firstIndex(of: "DIRECT") {
                    proxy.outbounds.remove(at: i)
                    proxy.outbounds.append("DIRECT")
                }
                configEngine.config.outbounds[proxyIdx] = .selector(proxy)
            }
        }

        // Add subscription group + region groups to service selectors (OpenAI, Google, etc.)
        for i in configEngine.config.outbounds.indices {
            if case .selector(var sel) = configEngine.config.outbounds[i],
               sel.tag != "Proxy" && sel.tag != "DIRECT" && !sel.tag.hasPrefix("📦") &&
               !sel.tag.contains("漏网之鱼") && !regionGroups.keys.contains(sel.tag) {
                var changed = false
                // Add Proxy if missing
                if !sel.outbounds.contains("Proxy") {
                    sel.outbounds.insert("Proxy", at: 0)
                    changed = true
                }
                // Add subscription group
                if !sel.outbounds.contains(subGroupTag) {
                    sel.outbounds.append(subGroupTag)
                    changed = true
                }
                // Add region groups
                for regionName in regionGroups.keys.sorted() {
                    if !sel.outbounds.contains(regionName) {
                        sel.outbounds.append(regionName)
                        changed = true
                    }
                }
                if changed {
                    configEngine.config.outbounds[i] = .selector(sel)
                }
            }
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

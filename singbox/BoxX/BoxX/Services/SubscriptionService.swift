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

        // Collect all subscription group tags and sorted region names
        let allSubTags = configEngine.config.outbounds.compactMap { $0.tag.hasPrefix("📦") ? $0.tag : nil }
        let sortedRegions = regionGroups.keys.sorted()

        // Find groups that reference Proxy (can't add to Proxy — would cause circular dep)
        let refsProxy: Set<String> = Set(configEngine.config.outbounds.compactMap { ob -> String? in
            switch ob {
            case .selector(let s): return s.outbounds.contains("Proxy") ? s.tag : nil
            case .urltest(let u): return u.outbounds.contains("Proxy") ? u.tag : nil
            default: return nil
            }
        })

        // Build the standard outbounds order for Proxy: subscriptions → regions → DIRECT
        // Skip groups that reference Proxy to avoid circular dependency
        func buildProxyOutbounds(existing: [String]) -> [String] {
            var result: [String] = []
            for tag in allSubTags where !result.contains(tag) && !refsProxy.contains(tag) { result.append(tag) }
            for tag in sortedRegions where !result.contains(tag) && !refsProxy.contains(tag) { result.append(tag) }
            let systemTags: Set<String> = Set(allSubTags + sortedRegions + ["Proxy", "DIRECT"])
            for tag in existing where !systemTags.contains(tag) && !result.contains(tag) && !refsProxy.contains(tag) {
                result.append(tag)
            }
            result.append("DIRECT")
            return result
        }

        // Update Proxy
        if let proxyIdx = configEngine.config.outbounds.firstIndex(where: { $0.tag == "Proxy" }) {
            if case .selector(var proxy) = configEngine.config.outbounds[proxyIdx] {
                proxy.outbounds = buildProxyOutbounds(existing: proxy.outbounds)
                configEngine.config.outbounds[proxyIdx] = .selector(proxy)
            }
        }

        // Update 漏网之鱼
        if let fishIdx = configEngine.config.outbounds.firstIndex(where: { $0.tag.contains("漏网之鱼") }) {
            if case .selector(var fish) = configEngine.config.outbounds[fishIdx] {
                var result = ["Proxy"]
                for tag in allSubTags where !result.contains(tag) { result.append(tag) }
                for tag in sortedRegions where !result.contains(tag) { result.append(tag) }
                result.append("DIRECT")
                fish.outbounds = result
                configEngine.config.outbounds[fishIdx] = .selector(fish)
            }
        }

        // Update service selectors (OpenAI, Google, etc.): Proxy → DIRECT → 漏网之鱼 → subscriptions → regions
        let fishTag = configEngine.config.outbounds.first(where: { $0.tag.contains("漏网之鱼") })?.tag
        let allRegionKeys = Set(regionGroups.keys).union(["🌐其他"])  // 🌐其他 is auto-generated catch-all
        for i in configEngine.config.outbounds.indices {
            if case .selector(var sel) = configEngine.config.outbounds[i],
               sel.tag != "Proxy" && sel.tag != "DIRECT" && !sel.tag.hasPrefix("📦") &&
               !sel.tag.contains("漏网之鱼") && !allRegionKeys.contains(sel.tag) {
                var result = ["Proxy", "DIRECT"]
                if let ft = fishTag { result.append(ft) }
                for tag in allSubTags where !result.contains(tag) { result.append(tag) }
                for tag in sortedRegions where !result.contains(tag) { result.append(tag) }
                sel.outbounds = result
                configEngine.config.outbounds[i] = .selector(sel)
            }
        }
    }

    private func ensureSelectorExists(tag: String, nodeTags: [String]) {
        if let index = configEngine.config.outbounds.firstIndex(where: { $0.tag == tag }) {
            // Update existing: replace node tags entirely (avoid cross-subscription duplicates)
            if case .selector(var selector) = configEngine.config.outbounds[index] {
                // Keep non-node items (groups like Proxy, DIRECT, etc.)
                let nodeSet = Set(nodeTags)
                let existingNodes = Set(selector.outbounds)
                // Merge: existing items + new nodes not already present
                var seen = Set<String>()
                var deduped: [String] = []
                for t in selector.outbounds + nodeTags {
                    if !seen.contains(t) { seen.insert(t); deduped.append(t) }
                }
                selector.outbounds = deduped
                configEngine.config.outbounds[index] = .selector(selector)
            }
        } else {
            // Create new selector (deduplicate)
            var seen = Set<String>()
            let deduped = nodeTags.filter { seen.insert($0).inserted }
            let selector = SelectorOutbound(tag: tag, outbounds: deduped)
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

// BoxX/Services/AutoGrouper.swift
import Foundation

struct AutoGrouper: Sendable {
    struct RegionDef: Sendable {
        let name: String
        let emoji: String
        let keywords: [String]
    }

    static let regions: [RegionDef] = [
        RegionDef(name: "香港", emoji: "🇭🇰", keywords: ["香港", "hk", "hong kong", "hongkong"]),
        RegionDef(name: "台湾", emoji: "🇹🇼", keywords: ["台湾", "tw", "taiwan"]),
        RegionDef(name: "日本", emoji: "🇯🇵", keywords: ["日本", "jp", "japan", "tokyo"]),
        RegionDef(name: "韩国", emoji: "🇰🇷", keywords: ["韩国", "kr", "korea"]),
        RegionDef(name: "新加坡", emoji: "🇸🇬", keywords: ["新加坡", "sg", "singapore"]),
        RegionDef(name: "美国", emoji: "🇺🇸", keywords: ["美国", "us", "usa", "united states", "los angeles", "san jose"]),
    ]

    /// Default patterns derived from the hardcoded regions.
    func defaultPatterns() -> [String: GroupPattern] {
        [
            "🇭🇰香港": GroupPattern(mode: "keyword", patterns: ["香港", "hk", "hong kong", "hongkong"]),
            "🇹🇼台湾": GroupPattern(mode: "keyword", patterns: ["台湾", "tw", "taiwan"]),
            "🇯🇵日本": GroupPattern(mode: "keyword", patterns: ["日本", "jp", "japan", "tokyo"]),
            "🇰🇷韩国": GroupPattern(mode: "keyword", patterns: ["韩国", "kr", "korea"]),
            "🇸🇬新加坡": GroupPattern(mode: "keyword", patterns: ["新加坡", "sg", "singapore"]),
            "🇺🇸美国": GroupPattern(mode: "keyword", patterns: ["美国", "us", "usa", "united states"]),
        ]
    }

    /// Group outbounds using configurable patterns. Returns [groupName: [tag]]
    func groupByPatterns(_ outbounds: [Outbound], patterns: [String: GroupPattern]) -> [String: [String]] {
        var groups: [String: [String]] = [:]

        for outbound in outbounds {
            let tag = outbound.tag
            var matched = false

            for (groupName, pattern) in patterns {
                let matches: Bool
                if pattern.mode == "regex" {
                    matches = pattern.patterns.contains { regex in
                        tag.range(of: regex, options: .regularExpression, range: nil, locale: nil) != nil
                    }
                } else {
                    // keyword mode (case insensitive)
                    let lower = tag.lowercased()
                    matches = pattern.patterns.contains { lower.contains($0.lowercased()) }
                }

                if matches {
                    groups[groupName, default: []].append(tag)
                    matched = true
                    break
                }
            }

            if !matched {
                groups["🌐其他", default: []].append(tag)
            }
        }

        return groups
    }

    /// Legacy fallback: group by hardcoded regions.
    func groupByRegion(_ outbounds: [Outbound]) -> [String: [String]] {
        return groupByPatterns(outbounds, patterns: defaultPatterns())
    }

    /// Group outbound tags by subscription source. Returns [tag]
    func groupBySubscription(name: String, outbounds: [Outbound]) -> [String] {
        return outbounds.map { $0.tag }
    }
}

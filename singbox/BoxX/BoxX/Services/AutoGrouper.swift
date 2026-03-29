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

    /// Group outbound tags by region. Returns [groupName: [tag]]
    func groupByRegion(_ outbounds: [Outbound]) -> [String: [String]] {
        var groups: [String: [String]] = [:]
        for outbound in outbounds {
            let tag = outbound.tag
            let lower = tag.lowercased()
            var matched = false
            for region in Self.regions {
                if region.keywords.contains(where: { lower.contains($0) }) {
                    let groupName = "\(region.emoji)\(region.name)"
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

    /// Group outbound tags by subscription source. Returns [tag]
    func groupBySubscription(name: String, outbounds: [Outbound]) -> [String] {
        return outbounds.map { $0.tag }
    }
}

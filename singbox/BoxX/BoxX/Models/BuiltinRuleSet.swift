// BoxX/Models/BuiltinRuleSet.swift
import Foundation

struct BuiltinRuleSet: Sendable, Identifiable {
    let id: String
    let name: String
    let emoji: String
    let geositeNames: [String]
    let defaultOutbound: String

    var displayName: String { "\(emoji)\(name)" }

    /// Generate the remote rule_set definitions for this service
    var ruleSetDefinitions: [JSONValue] {
        geositeNames.map { geosite in
            .object([
                "type": .string("remote"),
                "tag": .string("geosite-\(geosite)"),
                "format": .string("binary"),
                "url": .string("https://testingcf.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-\(geosite).srs"),
                "download_detour": .string("DIRECT"),
            ])
        }
    }

    /// Generate the route rule that uses these rule sets
    var routeRule: JSONValue {
        .object([
            "rule_set": .array(geositeNames.map { .string("geosite-\($0)") }),
            "action": .string("route"),
            "outbound": .string(defaultOutbound),
        ])
    }

    /// Order matters! More specific services must come before more general ones.
    /// e.g. YouTube before Google (youtube.com is also in geosite-google).
    static let all: [BuiltinRuleSet] = [
        BuiltinRuleSet(id: "ai", name: "OpenAI", emoji: "\u{1F916}", geositeNames: ["openai", "anthropic", "category-ai-chat-!cn"], defaultOutbound: "\u{1F916}OpenAI"),
        BuiltinRuleSet(id: "youtube", name: "YouTube", emoji: "\u{1F4FA}", geositeNames: ["youtube"], defaultOutbound: "\u{1F4FA}YouTube"),
        BuiltinRuleSet(id: "netflix", name: "Netflix", emoji: "\u{1F3AC}", geositeNames: ["netflix"], defaultOutbound: "\u{1F3AC}Netflix"),
        BuiltinRuleSet(id: "disney", name: "Disney", emoji: "\u{1F3F0}", geositeNames: ["disney"], defaultOutbound: "\u{1F3F0}Disney"),
        BuiltinRuleSet(id: "tiktok", name: "TikTok", emoji: "\u{1F3B5}", geositeNames: ["tiktok"], defaultOutbound: "\u{1F3B5}TikTok"),
        BuiltinRuleSet(id: "notion", name: "Notion", emoji: "\u{1F4DD}", geositeNames: ["notion"], defaultOutbound: "\u{1F4DD}Notion"),
        BuiltinRuleSet(id: "google", name: "Google", emoji: "\u{1F50D}", geositeNames: ["google"], defaultOutbound: "\u{1F50D}Google"),
        BuiltinRuleSet(id: "microsoft", name: "Microsoft", emoji: "\u{1F4BB}", geositeNames: ["github", "microsoft"], defaultOutbound: "\u{1F4BB}Microsoft"),
        BuiltinRuleSet(id: "apple", name: "Apple", emoji: "\u{1F34E}", geositeNames: ["apple"], defaultOutbound: "\u{1F34E}Apple"),
    ]
}

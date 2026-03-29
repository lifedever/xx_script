// BoxX/SwiftData/DataModels.swift
import Foundation
import SwiftData

@Model
final class SubscriptionRecord {
    var name: String
    var url: String
    var lastUpdated: Date?
    var nodeCount: Int

    init(name: String, url: String, lastUpdated: Date? = nil, nodeCount: Int = 0) {
        self.name = name
        self.url = url
        self.lastUpdated = lastUpdated
        self.nodeCount = nodeCount
    }
}

@Model
final class UserRuleSetConfig {
    var ruleSetId: String
    var enabled: Bool
    var outbound: String
    var order: Int

    init(ruleSetId: String, enabled: Bool = true, outbound: String = "Proxy", order: Int = 0) {
        self.ruleSetId = ruleSetId
        self.enabled = enabled
        self.outbound = outbound
        self.order = order
    }
}

@Model
final class AppPreference {
    var launchAtLogin: Bool
    var scriptDirectory: String?

    init(launchAtLogin: Bool = false, scriptDirectory: String? = nil) {
        self.launchAtLogin = launchAtLogin
        self.scriptDirectory = scriptDirectory
    }
}

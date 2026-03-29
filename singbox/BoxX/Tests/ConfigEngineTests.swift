// Tests/ConfigEngineTests.swift
import XCTest
@testable import BoxX

final class SingBoxConfigTests: XCTestCase {
    func testRealConfigRoundTrip() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/config.json")
        let data = try Data(contentsOf: fixtureURL)

        let config = try JSONDecoder().decode(SingBoxConfig.self, from: data)

        // Verify key structures loaded
        XCTAssertFalse(config.outbounds.isEmpty, "outbounds should not be empty")
        XCTAssertFalse(config.inbounds.isEmpty, "inbounds should not be empty")
        XCTAssertNotNil(config.route.rules, "route.rules should exist")
        XCTAssertNotNil(config.dns, "dns should exist")
        XCTAssertNotNil(config.experimental, "experimental should exist")
        XCTAssertNotNil(config.log, "log should exist")

        // Verify outbound count
        XCTAssertEqual(config.outbounds.count, 114, "should have 114 outbounds")

        // Verify route rules count
        XCTAssertEqual(config.route.rules?.count, 22, "should have 22 route rules")

        // Verify route rule_set count
        XCTAssertEqual(config.route.ruleSet?.count, 22, "should have 22 rule sets")

        // Verify ntp preserved in unknownFields
        XCTAssertNotNil(config.unknownFields["ntp"], "ntp should be preserved in unknownFields")

        // Round-trip: encode and decode again
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(config)
        let redecoded = try JSONDecoder().decode(SingBoxConfig.self, from: encoded)

        // Verify counts preserved after round-trip
        XCTAssertEqual(config.outbounds.count, redecoded.outbounds.count, "outbound count should survive round-trip")
        XCTAssertEqual(config.route.rules?.count, redecoded.route.rules?.count, "route rules count should survive round-trip")
        XCTAssertEqual(config.route.ruleSet?.count, redecoded.route.ruleSet?.count, "rule set count should survive round-trip")
    }

    func testClashApiConfig() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/config.json")
        let data = try Data(contentsOf: fixtureURL)
        let config = try JSONDecoder().decode(SingBoxConfig.self, from: data)

        XCTAssertEqual(config.experimental?.clashApi?.externalController, "127.0.0.1:9091")
        XCTAssertEqual(config.experimental?.clashApi?.defaultMode, "rule")
    }
}

// MARK: - ConfigEngine Tests

final class ConfigEngineLoadSaveTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadRealConfig() throws {
        // Copy fixture to temp dir
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/config.json")
        let tempConfig = tempDir.appendingPathComponent("config.json")
        try FileManager.default.copyItem(at: fixtureURL, to: tempConfig)

        let engine = ConfigEngine(baseDir: tempDir)
        try engine.load()

        XCTAssertFalse(engine.config.outbounds.isEmpty)
        XCTAssertEqual(engine.config.outbounds.count, 114)
    }

    func testSaveAndReload() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/config.json")
        let tempConfig = tempDir.appendingPathComponent("config.json")
        try FileManager.default.copyItem(at: fixtureURL, to: tempConfig)

        let engine = ConfigEngine(baseDir: tempDir)
        try engine.load()
        let originalCount = engine.config.outbounds.count

        // Save
        try engine.save()

        // Reload and verify
        let engine2 = ConfigEngine(baseDir: tempDir)
        try engine2.load()
        XCTAssertEqual(engine2.config.outbounds.count, originalCount)
    }

    func testMergeProxies() throws {
        // Create minimal config.json
        let coreConfig = SingBoxConfig(
            inbounds: [],
            outbounds: [
                .selector(SelectorOutbound(tag: "Proxy", outbounds: ["DIRECT"])),
                .direct(DirectOutbound(tag: "DIRECT"))
            ],
            route: RouteConfig()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configData = try encoder.encode(coreConfig)
        try configData.write(to: tempDir.appendingPathComponent("config.json"))

        // Create proxies directory with subscription nodes
        let proxiesDir = tempDir.appendingPathComponent("proxies")
        try FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)
        let nodes: [Outbound] = [
            .vmess(VMessOutbound(tag: "HK-01", server: "a.com", serverPort: 443, uuid: "u")),
            .vmess(VMessOutbound(tag: "HK-02", server: "b.com", serverPort: 443, uuid: "v"))
        ]
        let nodesData = try encoder.encode(nodes)
        try nodesData.write(to: proxiesDir.appendingPathComponent("TestSub.json"))

        // Load and merge
        let engine = ConfigEngine(baseDir: tempDir)
        try engine.load()

        XCTAssertEqual(engine.config.outbounds.count, 2, "Core config has 2 outbounds")
        XCTAssertEqual(engine.proxies["TestSub"]?.count, 2, "Subscription has 2 nodes")

        let runtime = engine.buildRuntimeConfig()
        XCTAssertEqual(runtime.outbounds.count, 4, "Runtime should merge core (2) + proxies (2)")

        let tags = runtime.outbounds.map { $0.tag }
        XCTAssertTrue(tags.contains("Proxy"))
        XCTAssertTrue(tags.contains("DIRECT"))
        XCTAssertTrue(tags.contains("HK-01"))
        XCTAssertTrue(tags.contains("HK-02"))
    }

    func testSaveProxies() throws {
        // Create minimal config
        let configData = try JSONEncoder().encode(SingBoxConfig(inbounds: [], outbounds: [], route: RouteConfig()))
        try configData.write(to: tempDir.appendingPathComponent("config.json"))

        let engine = ConfigEngine(baseDir: tempDir)
        try engine.load()

        // Save proxy nodes
        let nodes: [Outbound] = [
            .vmess(VMessOutbound(tag: "JP-01", server: "jp.com", serverPort: 443, uuid: "x"))
        ]
        try engine.saveProxies(name: "MySub", nodes: nodes)

        XCTAssertEqual(engine.proxies["MySub"]?.count, 1)

        // Verify file was written
        let filePath = tempDir.appendingPathComponent("proxies/MySub.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath.path))

        // Reload and verify persistence
        let engine2 = ConfigEngine(baseDir: tempDir)
        try engine2.load()
        XCTAssertEqual(engine2.proxies["MySub"]?.count, 1)
    }

    func testRemoveProxies() throws {
        let configData = try JSONEncoder().encode(SingBoxConfig(inbounds: [], outbounds: [], route: RouteConfig()))
        try configData.write(to: tempDir.appendingPathComponent("config.json"))

        let engine = ConfigEngine(baseDir: tempDir)
        try engine.load()

        let nodes: [Outbound] = [.direct(DirectOutbound(tag: "test"))]
        try engine.saveProxies(name: "ToRemove", nodes: nodes)
        XCTAssertEqual(engine.proxies.count, 1)

        try engine.removeProxies(name: "ToRemove")
        XCTAssertEqual(engine.proxies.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("proxies/ToRemove.json").path))
    }

    // MARK: - Rule Priority Tests

    func testUserRuleInsertedBeforeServiceRules() throws {
        // Simulate a config with system rules + service rules (like BuiltinRuleSet adds)
        var config = SingBoxConfig(inbounds: [], outbounds: [], route: RouteConfig())
        config.route.rules = [
            // System rules (should stay at top)
            .object(["action": .string("sniff")]),
            .object(["action": .string("hijack-dns")]),
            .object(["ip_is_private": .bool(true), "action": .string("route"), "outbound": .string("DIRECT")]),
            // Service rules (added by BuiltinRuleSet)
            .object(["rule_set": .array([.string("geosite-youtube")]), "action": .string("route"), "outbound": .string("YouTube")]),
            .object(["rule_set": .array([.string("geosite-google")]), "action": .string("route"), "outbound": .string("Google")]),
            .object(["rule_set": .array([.string("geosite-geolocation-!cn")]), "action": .string("route"), "outbound": .string("Proxy")]),
        ]

        // Simulate adding a user-defined rule (same logic as AddRuleSheet.saveAsLocalRule)
        let userRule = JSONValue.object([
            "domain_suffix": .array([.string("example.com")]),
            "action": .string("route"),
            "outbound": .string("DIRECT"),
        ])

        var rules = config.route.rules!
        let insertIdx = rules.firstIndex(where: { rule in
            rule["rule_set"] != nil || rule["domain"] != nil || rule["domain_suffix"] != nil
        }) ?? rules.count
        rules.insert(userRule, at: insertIdx)

        // Verify: user rule should be at index 3 (after 3 system rules, before service rules)
        XCTAssertEqual(insertIdx, 3, "User rule should be inserted after system rules")
        XCTAssertEqual(rules[3]["domain_suffix"]?.arrayValue?.first?.stringValue, "example.com",
                       "User rule should be at position 3")

        // Verify system rules are still at top
        XCTAssertEqual(rules[0]["action"]?.stringValue, "sniff")
        XCTAssertEqual(rules[1]["action"]?.stringValue, "hijack-dns")

        // Verify service rules are after user rule
        XCTAssertEqual(rules[4]["rule_set"]?.arrayValue?.first?.stringValue, "geosite-youtube")
        XCTAssertEqual(rules[5]["rule_set"]?.arrayValue?.first?.stringValue, "geosite-google")
    }

    func testBuiltinRuleSetOrderYouTubeBeforeGoogle() {
        // Verify that in BuiltinRuleSet.all, YouTube comes before Google
        let ids = BuiltinRuleSet.all.map(\.id)
        guard let youtubeIdx = ids.firstIndex(of: "youtube"),
              let googleIdx = ids.firstIndex(of: "google") else {
            XCTFail("YouTube and Google must be in BuiltinRuleSet.all")
            return
        }
        XCTAssertLessThan(youtubeIdx, googleIdx,
                          "YouTube must come before Google to prevent geosite-google from matching youtube.com first")
    }

    func testMultipleUserRulesInsertedInOrder() throws {
        var rules: [JSONValue] = [
            .object(["action": .string("sniff")]),
            .object(["rule_set": .array([.string("geosite-google")]), "action": .string("route"), "outbound": .string("Google")]),
        ]

        // Add first user rule
        let rule1 = JSONValue.object(["domain_suffix": .array([.string("first.com")]), "action": .string("route"), "outbound": .string("DIRECT")])
        let idx1 = rules.firstIndex(where: { $0["rule_set"] != nil || $0["domain"] != nil || $0["domain_suffix"] != nil }) ?? rules.count
        rules.insert(rule1, at: idx1)

        // Add second user rule
        let rule2 = JSONValue.object(["domain": .array([.string("second.com")]), "action": .string("route"), "outbound": .string("Proxy")])
        let idx2 = rules.firstIndex(where: { $0["rule_set"] != nil || $0["domain"] != nil || $0["domain_suffix"] != nil }) ?? rules.count
        rules.insert(rule2, at: idx2)

        // Expected order: sniff, rule2(second.com), rule1(first.com), geosite-google
        // rule2 inserted at position 1 (first rule_set/domain match is rule1 at position 1)
        // So rule2 goes before rule1 — newer user rules have higher priority
        XCTAssertEqual(rules[0]["action"]?.stringValue, "sniff")
        XCTAssertNotNil(rules[1]["domain"] ?? rules[1]["domain_suffix"], "Position 1 should be a user rule")
        XCTAssertNotNil(rules[2]["domain"] ?? rules[2]["domain_suffix"], "Position 2 should be a user rule")
        XCTAssertNotNil(rules[3]["rule_set"], "Position 3 should be geosite-google")
    }

    func testDeployRuntime() async throws {
        let configData = try JSONEncoder().encode(SingBoxConfig(
            inbounds: [],
            outbounds: [.direct(DirectOutbound(tag: "DIRECT"))],
            route: RouteConfig()
        ))
        try configData.write(to: tempDir.appendingPathComponent("config.json"))

        let engine = ConfigEngine(baseDir: tempDir)
        try engine.load()

        let nodes: [Outbound] = [.vmess(VMessOutbound(tag: "N1", server: "s.com", serverPort: 1, uuid: "u"))]
        try engine.saveProxies(name: "Sub1", nodes: nodes)

        try await engine.deployRuntime()

        // Verify runtime-config.json was created
        let runtimePath = tempDir.appendingPathComponent("runtime-config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimePath.path))

        // Verify it contains merged outbounds
        let runtimeData = try Data(contentsOf: runtimePath)
        let runtimeConfig = try JSONDecoder().decode(SingBoxConfig.self, from: runtimeData)
        XCTAssertEqual(runtimeConfig.outbounds.count, 2) // DIRECT + N1
    }
}

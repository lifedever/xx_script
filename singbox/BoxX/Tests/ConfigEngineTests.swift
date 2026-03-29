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

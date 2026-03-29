// Tests/AutoGrouperTests.swift
import XCTest
@testable import BoxX

final class AutoGrouperTests: XCTestCase {
    let grouper = AutoGrouper()

    private func makeOutbound(tag: String) -> Outbound {
        .direct(DirectOutbound(tag: tag))
    }

    func testGroupByRegion() {
        let outbounds: [Outbound] = [
            makeOutbound(tag: "🇭🇰 香港 01"),
            makeOutbound(tag: "HK-02"),
            makeOutbound(tag: "🇯🇵 日本 01"),
            makeOutbound(tag: "JP-Tokyo"),
            makeOutbound(tag: "🇺🇸 US-01"),
            makeOutbound(tag: "🇸🇬 Singapore 01"),
            makeOutbound(tag: "Random Node"),
        ]
        let groups = grouper.groupByRegion(outbounds)

        XCTAssertEqual(groups["🇭🇰香港"]?.count, 2)
        XCTAssertEqual(groups["🇯🇵日本"]?.count, 2)
        XCTAssertEqual(groups["🇺🇸美国"]?.count, 1)
        XCTAssertEqual(groups["🇸🇬新加坡"]?.count, 1)
        XCTAssertEqual(groups["🌐其他"]?.count, 1)
    }

    func testGroupByRegionCaseInsensitive() {
        let outbounds: [Outbound] = [
            makeOutbound(tag: "Hong Kong Server"),
            makeOutbound(tag: "JAPAN-01"),
            makeOutbound(tag: "taiwan node"),
        ]
        let groups = grouper.groupByRegion(outbounds)

        XCTAssertEqual(groups["🇭🇰香港"]?.count, 1)
        XCTAssertEqual(groups["🇯🇵日本"]?.count, 1)
        XCTAssertEqual(groups["🇹🇼台湾"]?.count, 1)
    }

    func testGroupByRegionAllUnknown() {
        let outbounds: [Outbound] = [
            makeOutbound(tag: "Server A"),
            makeOutbound(tag: "Server B"),
        ]
        let groups = grouper.groupByRegion(outbounds)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups["🌐其他"]?.count, 2)
    }

    func testGroupByRegionEmpty() {
        let groups = grouper.groupByRegion([])
        XCTAssertTrue(groups.isEmpty)
    }

    func testKoreaKeyword() {
        let outbounds: [Outbound] = [
            makeOutbound(tag: "🇰🇷 韩国 01"),
            makeOutbound(tag: "Korea-Premium"),
        ]
        let groups = grouper.groupByRegion(outbounds)
        XCTAssertEqual(groups["🇰🇷韩国"]?.count, 2)
    }
}

import XCTest
@testable import BoxX

final class ProxyModelsTests: XCTestCase {
    func testProxyGroupDecoding() throws {
        let json = """
        {"type":"Selector","name":"Proxy","udp":true,"history":[],"now":"SoCloud","all":["SoCloud","HK","US"]}
        """.data(using: .utf8)!
        let group = try JSONDecoder().decode(ProxyGroup.self, from: json)
        XCTAssertEqual(group.name, "Proxy")
        XCTAssertEqual(group.type, "Selector")
        XCTAssertEqual(group.now, "SoCloud")
        XCTAssertEqual(group.displayAll.count, 3)
    }

    func testConnectionDecoding() throws {
        let json = """
        {"chains":["DIRECT"],"download":4530610,"id":"abc-123","metadata":{"destinationIP":"1.2.3.4","destinationPort":"443","dnsMode":"normal","host":"example.com","network":"tcp","processPath":"","sourceIP":"172.19.0.1","sourcePort":"60934","type":"tun"},"rule":"route(DIRECT)","rulePayload":"","start":"2026-03-29T10:23:19+08:00","upload":68626}
        """.data(using: .utf8)!
        let conn = try JSONDecoder().decode(Connection.self, from: json)
        XCTAssertEqual(conn.id, "abc-123")
        XCTAssertEqual(conn.host, "example.com")
        XCTAssertEqual(conn.download, 4530610)
    }

    func testRuleDecoding() throws {
        let json = """
        {"type":"logical","payload":"protocol=dns","proxy":"hijack-dns"}
        """.data(using: .utf8)!
        let rule = try JSONDecoder().decode(Rule.self, from: json)
        XCTAssertEqual(rule.type, "logical")
        XCTAssertEqual(rule.proxy, "hijack-dns")
    }
}

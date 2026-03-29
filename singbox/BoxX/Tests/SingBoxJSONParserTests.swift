// Tests/SingBoxJSONParserTests.swift
import XCTest
@testable import BoxX

final class SingBoxJSONParserTests: XCTestCase {

    func testCanParseObjectFormat() {
        let json = """
        {"outbounds":[{"type":"vmess","tag":"test","server":"a.com","server_port":443,"uuid":"x","alter_id":0,"security":"auto"}]}
        """.data(using: .utf8)!
        let parser = SingBoxJSONParser()
        XCTAssertTrue(parser.canParse(json))
    }

    func testCanParseArrayFormat() {
        let json = """
        [{"type":"vmess","tag":"test","server":"a.com","server_port":443,"uuid":"x"}]
        """.data(using: .utf8)!
        let parser = SingBoxJSONParser()
        XCTAssertTrue(parser.canParse(json))
    }

    func testCanNotParseYAML() {
        let yaml = "proxies:\n  - name: test\n    type: vmess\n".data(using: .utf8)!
        let parser = SingBoxJSONParser()
        XCTAssertFalse(parser.canParse(yaml))
    }

    func testParseObjectFormat() throws {
        let json = """
        {"outbounds":[
            {"type":"vmess","tag":"HK-01","server":"hk.example.com","server_port":443,"uuid":"abc","alter_id":0,"security":"auto"},
            {"type":"vless","tag":"JP-01","server":"jp.example.com","server_port":443,"uuid":"def","flow":"xtls-rprx-vision","tls":{"enabled":true}},
            {"type":"selector","tag":"Proxy","outbounds":["HK-01","JP-01"]},
            {"type":"direct","tag":"DIRECT"}
        ]}
        """.data(using: .utf8)!
        let parser = SingBoxJSONParser()
        let nodes = try parser.parse(json)

        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].tag, "HK-01")
        XCTAssertEqual(nodes[0].type, .vmess)
        XCTAssertEqual(nodes[0].server, "hk.example.com")
        XCTAssertEqual(nodes[0].port, 443)
        XCTAssertEqual(nodes[1].tag, "JP-01")
        XCTAssertEqual(nodes[1].type, .vless)
    }

    func testParseArrayFormat() throws {
        let json = """
        [
            {"type":"shadowsocks","tag":"SS-01","server":"ss.example.com","server_port":8388,"method":"aes-128-gcm","password":"pwd"},
            {"type":"hysteria2","tag":"HY-01","server":"hy.example.com","server_port":443,"password":"pwd","tls":{"enabled":true}}
        ]
        """.data(using: .utf8)!
        let parser = SingBoxJSONParser()
        let nodes = try parser.parse(json)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].type, .shadowsocks)
        XCTAssertEqual(nodes[1].type, .hysteria2)
    }

    func testParsedProxyToOutbound() throws {
        let json = """
        [{"type":"vmess","tag":"Test","server":"s.com","server_port":443,"uuid":"u","alter_id":0,"security":"auto","tls":{"enabled":true}}]
        """.data(using: .utf8)!
        let parser = SingBoxJSONParser()
        let nodes = try parser.parse(json)
        let outbound = nodes[0].toOutbound()

        XCTAssertEqual(outbound.tag, "Test")
        if case .vmess(let v) = outbound {
            XCTAssertEqual(v.server, "s.com")
            XCTAssertEqual(v.uuid, "u")
            XCTAssertNotNil(v.unknownFields["tls"])
        } else {
            XCTFail("Expected vmess outbound")
        }
    }

    func testParseRealConfig() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/config.json")
        let data = try Data(contentsOf: fixtureURL)
        let parser = SingBoxJSONParser()

        XCTAssertTrue(parser.canParse(data))

        let nodes = try parser.parse(data)
        XCTAssertGreaterThan(nodes.count, 0)
        for node in nodes {
            XCTAssertTrue([.vmess, .shadowsocks, .trojan, .hysteria2, .vless].contains(node.type),
                          "Unexpected type: \(node.type) for \(node.tag)")
        }
    }
}

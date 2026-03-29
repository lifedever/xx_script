// Tests/ClashYAMLParserTests.swift
import XCTest
@testable import BoxX

final class ClashYAMLParserTests: XCTestCase {
    let sampleYAML = """
    proxies:
      - name: "🇭🇰 HK-01"
        type: vmess
        server: hk.example.com
        port: 443
        uuid: abc-def-123
        alterId: 0
        cipher: auto
        tls: true
        servername: hk.example.com
        network: ws
        ws-opts:
          path: /ws
          headers:
            Host: hk.example.com
      - name: "🇯🇵 JP-SS"
        type: ss
        server: jp.example.com
        port: 8388
        cipher: aes-128-gcm
        password: mypassword
      - name: "🇺🇸 US-Trojan"
        type: trojan
        server: us.example.com
        port: 443
        password: trojanpwd
        sni: us.example.com
      - name: "🇸🇬 SG-HY2"
        type: hy2
        server: sg.example.com
        port: 443
        password: hy2pwd
        sni: sg.example.com
      - name: "🇹🇼 TW-VLESS"
        type: vless
        server: tw.example.com
        port: 443
        uuid: vless-uuid
        flow: xtls-rprx-vision
        tls: true
        servername: tw.example.com
        reality-opts:
          public-key: pubkey123
          short-id: shortid456
    """

    func testCanParse() {
        let parser = ClashYAMLParser()
        XCTAssertTrue(parser.canParse(sampleYAML.data(using: .utf8)!))
    }

    func testCanNotParseJSON() {
        let json = """
        {"outbounds":[{"type":"vmess"}]}
        """.data(using: .utf8)!
        let parser = ClashYAMLParser()
        XCTAssertFalse(parser.canParse(json))
    }

    func testParseAllTypes() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(sampleYAML.data(using: .utf8)!)
        XCTAssertEqual(nodes.count, 5)

        // vmess
        XCTAssertEqual(nodes[0].tag, "🇭🇰 HK-01")
        XCTAssertEqual(nodes[0].type, .vmess)
        XCTAssertEqual(nodes[0].server, "hk.example.com")
        XCTAssertEqual(nodes[0].port, 443)

        // shadowsocks
        XCTAssertEqual(nodes[1].tag, "🇯🇵 JP-SS")
        XCTAssertEqual(nodes[1].type, .shadowsocks)

        // trojan
        XCTAssertEqual(nodes[2].tag, "🇺🇸 US-Trojan")
        XCTAssertEqual(nodes[2].type, .trojan)

        // hysteria2
        XCTAssertEqual(nodes[3].tag, "🇸🇬 SG-HY2")
        XCTAssertEqual(nodes[3].type, .hysteria2)

        // vless
        XCTAssertEqual(nodes[4].tag, "🇹🇼 TW-VLESS")
        XCTAssertEqual(nodes[4].type, .vless)
    }

    func testVMessConversion() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(sampleYAML.data(using: .utf8)!)
        let outbound = nodes[0].toOutbound()

        guard case .vmess(let v) = outbound else { XCTFail("Expected vmess"); return }
        XCTAssertEqual(v.tag, "🇭🇰 HK-01")
        XCTAssertEqual(v.server, "hk.example.com")
        XCTAssertEqual(v.serverPort, 443)
        XCTAssertEqual(v.uuid, "abc-def-123")
        XCTAssertEqual(v.alterId, 0)
        XCTAssertEqual(v.security, "auto")
        // Should have transport in unknownFields
        XCTAssertNotNil(v.unknownFields["transport"])
        // Should have tls in unknownFields
        XCTAssertNotNil(v.unknownFields["tls"])
    }

    func testShadowsocksConversion() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(sampleYAML.data(using: .utf8)!)
        let outbound = nodes[1].toOutbound()

        guard case .shadowsocks(let ss) = outbound else { XCTFail("Expected shadowsocks"); return }
        XCTAssertEqual(ss.tag, "🇯🇵 JP-SS")
        XCTAssertEqual(ss.server, "jp.example.com")
        XCTAssertEqual(ss.method, "aes-128-gcm")
        XCTAssertEqual(ss.password, "mypassword")
    }

    func testTrojanConversion() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(sampleYAML.data(using: .utf8)!)
        let outbound = nodes[2].toOutbound()

        guard case .trojan(let t) = outbound else { XCTFail("Expected trojan"); return }
        XCTAssertEqual(t.tag, "🇺🇸 US-Trojan")
        XCTAssertEqual(t.server, "us.example.com")
        XCTAssertEqual(t.serverPort, 443)
        XCTAssertEqual(t.password, "trojanpwd")
        XCTAssertNotNil(t.unknownFields["tls"])
    }

    func testHysteria2Conversion() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(sampleYAML.data(using: .utf8)!)
        let outbound = nodes[3].toOutbound()

        guard case .hysteria2(let h) = outbound else { XCTFail("Expected hysteria2"); return }
        XCTAssertEqual(h.tag, "🇸🇬 SG-HY2")
        XCTAssertEqual(h.server, "sg.example.com")
        XCTAssertEqual(h.password, "hy2pwd")
        XCTAssertNotNil(h.unknownFields["tls"])
    }

    func testVLESSConversion() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(sampleYAML.data(using: .utf8)!)
        let outbound = nodes[4].toOutbound()

        guard case .vless(let vl) = outbound else { XCTFail("Expected vless"); return }
        XCTAssertEqual(vl.tag, "🇹🇼 TW-VLESS")
        XCTAssertEqual(vl.server, "tw.example.com")
        XCTAssertEqual(vl.uuid, "vless-uuid")
        XCTAssertEqual(vl.flow, "xtls-rprx-vision")
        XCTAssertNotNil(vl.unknownFields["tls"])
    }

    func testEmptyProxiesThrows() {
        let yaml = """
        proxies:
        """
        let parser = ClashYAMLParser()
        XCTAssertThrowsError(try parser.parse(yaml.data(using: .utf8)!))
    }
}

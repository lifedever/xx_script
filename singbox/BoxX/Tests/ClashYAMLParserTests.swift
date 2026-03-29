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

    // MARK: - Inline YAML format tests

    let inlineYAML = """
    proxies:
        - { name: '🇭🇰香港01', type: vless, server: example.com, port: 35248, uuid: test-uuid, udp: true, tls: true, skip-cert-verify: false, flow: xtls-rprx-vision, client-fingerprint: chrome, servername: www.example.com, reality-opts: { public-key: testpubkey, short-id: testshortid } }
        - { name: '🇭🇰香港-SS', type: ss, server: ss.example.com, port: 36602, cipher: aes-128-gcm, password: testpassword, plugin: obfs-local, plugin-opts: { mode: http, host: example.baidu.com } }
    """

    func testParseInlineVLESS() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(inlineYAML.data(using: .utf8)!)
        XCTAssertEqual(nodes.count, 2)

        // VLESS node
        XCTAssertEqual(nodes[0].tag, "🇭🇰香港01")
        XCTAssertEqual(nodes[0].type, .vless)
        XCTAssertEqual(nodes[0].server, "example.com")
        XCTAssertEqual(nodes[0].port, 35248)
    }

    func testParseInlineSS() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(inlineYAML.data(using: .utf8)!)

        // Shadowsocks node
        XCTAssertEqual(nodes[1].tag, "🇭🇰香港-SS")
        XCTAssertEqual(nodes[1].type, .shadowsocks)
        XCTAssertEqual(nodes[1].server, "ss.example.com")
        XCTAssertEqual(nodes[1].port, 36602)
    }

    func testInlineVLESSConversion() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(inlineYAML.data(using: .utf8)!)
        let outbound = nodes[0].toOutbound()

        guard case .vless(let vl) = outbound else { XCTFail("Expected vless"); return }
        XCTAssertEqual(vl.tag, "🇭🇰香港01")
        XCTAssertEqual(vl.server, "example.com")
        XCTAssertEqual(vl.uuid, "test-uuid")
        XCTAssertEqual(vl.flow, "xtls-rprx-vision")
        // TLS with reality should be present
        XCTAssertNotNil(vl.unknownFields["tls"])
    }

    func testInlineSSConversion() throws {
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(inlineYAML.data(using: .utf8)!)
        let outbound = nodes[1].toOutbound()

        guard case .shadowsocks(let ss) = outbound else { XCTFail("Expected shadowsocks"); return }
        XCTAssertEqual(ss.tag, "🇭🇰香港-SS")
        XCTAssertEqual(ss.server, "ss.example.com")
        XCTAssertEqual(ss.method, "aes-128-gcm")
        XCTAssertEqual(ss.password, "testpassword")
    }

    func testMixedInlineAndMultiline() throws {
        let mixed = """
        proxies:
            - { name: 'Inline-Node', type: ss, server: a.com, port: 1234, cipher: aes-128-gcm, password: pw }
          - name: "Multiline-Node"
            type: ss
            server: b.com
            port: 5678
            cipher: aes-256-gcm
            password: pw2
        """
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(mixed.data(using: .utf8)!)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].tag, "Inline-Node")
        XCTAssertEqual(nodes[1].tag, "Multiline-Node")
    }

    func testEmptyProxiesThrows() {
        let yaml = """
        proxies:
        """
        let parser = ClashYAMLParser()
        XCTAssertThrowsError(try parser.parse(yaml.data(using: .utf8)!))
    }

    // MARK: - Real subscription data patterns

    /// Test parsing nodes with unquoted colons in names (e.g. "套餐到期：长期有效")
    func testParseInlineUnquotedColonInName() throws {
        let yaml = """
        proxies:
            - { name: 套餐到期：长期有效, type: vless, server: example.com, port: 443, uuid: test-uuid, tls: true, servername: example.com }
            - { name: 剩余流量：980.32 GB, type: vless, server: example2.com, port: 443, uuid: test-uuid2, tls: true, servername: example2.com }
        """
        let parser = ClashYAMLParser()
        // These are info nodes, not real proxies. The parser should either
        // parse them (they have valid type/server/port) or skip them.
        // As long as it doesn't crash, the behavior is acceptable.
        let nodes = try parser.parse(yaml.data(using: .utf8)!)
        // Both have valid fields so they should parse
        XCTAssertEqual(nodes.count, 2)
    }

    /// Test parsing nodes with single-quoted names containing full-width colons
    func testParseInlineQuotedColonInName() throws {
        let yaml = """
        proxies:
            - { name: '🇭🇰香港高速01|BGP|流媒体', type: vless, server: aws-link1.example.com, port: 35248, uuid: abc-123, udp: true, tls: true, skip-cert-verify: false, flow: xtls-rprx-vision, client-fingerprint: chrome, servername: www.example.com, reality-opts: { public-key: pk123, short-id: sid456 } }
            - { name: '🇸🇬新加坡高速01|BGP', type: vless, server: sg.example.com, port: 35249, uuid: def-456, tls: true, servername: sg.example.com }
        """
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(yaml.data(using: .utf8)!)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].tag, "🇭🇰香港高速01|BGP|流媒体")
        XCTAssertEqual(nodes[0].port, 35248)
        XCTAssertEqual(nodes[1].tag, "🇸🇬新加坡高速01|BGP")
        XCTAssertEqual(nodes[1].port, 35249)
    }

    /// Test that a realistic mixed subscription (info lines + real proxies) parses correctly
    func testRealisticSubscription() throws {
        let yaml = """
        proxies:
            - { name: 套餐到期：长期有效, type: vless, server: placeholder.com, port: 1, uuid: 00000000-0000-0000-0000-000000000000, tls: true, servername: placeholder.com }
            - { name: 剩余流量：980.32 GB, type: vless, server: placeholder.com, port: 1, uuid: 00000000-0000-0000-0000-000000000000, tls: true, servername: placeholder.com }
            - { name: '🇭🇰香港高速01|BGP|流媒体', type: vless, server: hk.example.com, port: 35248, uuid: real-uuid-1, udp: true, tls: true, skip-cert-verify: false, flow: xtls-rprx-vision, client-fingerprint: chrome, servername: www.example.com, reality-opts: { public-key: pubkey1, short-id: shortid1 } }
            - { name: '🇯🇵日本高速01|BGP|流媒体', type: vless, server: jp.example.com, port: 35249, uuid: real-uuid-2, udp: true, tls: true, skip-cert-verify: false, flow: xtls-rprx-vision, client-fingerprint: chrome, servername: www.example.com, reality-opts: { public-key: pubkey2, short-id: shortid2 } }
            - { name: '🇭🇰香港-SS', type: ss, server: ss.example.com, port: 36602, cipher: aes-128-gcm, password: testpwd, plugin: obfs-local, plugin-opts: { mode: http, host: example.baidu.com } }
        """
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(yaml.data(using: .utf8)!)
        // All 5 lines have valid type/server/port, so all should parse
        XCTAssertEqual(nodes.count, 5)
        // Verify the real proxy nodes
        XCTAssertEqual(nodes[2].tag, "🇭🇰香港高速01|BGP|流媒体")
        XCTAssertEqual(nodes[2].type, .vless)
        XCTAssertEqual(nodes[2].port, 35248)
        XCTAssertEqual(nodes[3].tag, "🇯🇵日本高速01|BGP|流媒体")
        XCTAssertEqual(nodes[3].type, .vless)
        XCTAssertEqual(nodes[4].tag, "🇭🇰香港-SS")
        XCTAssertEqual(nodes[4].type, .shadowsocks)
    }

    /// Test that VLESS conversion produces valid sing-box JSON with reality opts
    func testRealisticVLESSConversion() throws {
        let yaml = """
        proxies:
            - { name: '🇭🇰香港01', type: vless, server: hk.example.com, port: 35248, uuid: real-uuid, udp: true, tls: true, skip-cert-verify: false, flow: xtls-rprx-vision, client-fingerprint: chrome, servername: www.example.com, reality-opts: { public-key: pubkey, short-id: shortid } }
        """
        let parser = ClashYAMLParser()
        let nodes = try parser.parse(yaml.data(using: .utf8)!)
        XCTAssertEqual(nodes.count, 1)
        let outbound = nodes[0].toOutbound()
        guard case .vless(let vl) = outbound else { XCTFail("Expected vless"); return }
        XCTAssertEqual(vl.tag, "🇭🇰香港01")
        XCTAssertEqual(vl.server, "hk.example.com")
        XCTAssertEqual(vl.serverPort, 35248)
        XCTAssertEqual(vl.uuid, "real-uuid")
        XCTAssertEqual(vl.flow, "xtls-rprx-vision")
        // TLS with reality should be in unknownFields
        XCTAssertNotNil(vl.unknownFields["tls"])
    }

    // MARK: - End-to-end subscription data test

    /// Test with exact real-world inline YAML data format (from issue #1)
    func testRealWorldInlineYAMLSubscription() throws {
        let yaml = """
        proxies:
            - { name: '🇭🇰香港高速01|BGP|流媒体', type: vless, server: aws-link1.liangxin1.xyz, port: 35248, uuid: 13f15b9b-763b-4982-bfb6-8f1dbe1f3c06, udp: true, tls: true, skip-cert-verify: false, flow: xtls-rprx-vision, client-fingerprint: chrome, servername: www.lamer.com.hk, reality-opts: { public-key: IGsSxC0wgn7wLy0NM0QN_yOREDKT_814Y_3_rbgDoTc, short-id: c8c0f951 } }
            - { name: '🇯🇵日本高速01|BGP|流媒体', type: vless, server: aws-link1.liangxin1.xyz, port: 35249, uuid: 13f15b9b-763b-4982-bfb6-8f1dbe1f3c06, udp: true, tls: true, skip-cert-verify: false, flow: xtls-rprx-vision, client-fingerprint: chrome, servername: www.lamer.com.hk, reality-opts: { public-key: IGsSxC0wgn7wLy0NM0QN_yOREDKT_814Y_3_rbgDoTc, short-id: c8c0f951 } }
            - { name: '🇭🇰香港-SS', type: ss, server: hk-ss.example.com, port: 36602, cipher: aes-128-gcm, password: Ntk2ODA2YjQ0, plugin: obfs-local, plugin-opts: { mode: http, host: cdn.baidu.com } }
            - { name: '🇺🇸美国-Trojan', type: trojan, server: us.example.com, port: 443, password: trojan-pwd-123, sni: us.example.com, skip-cert-verify: false }
            - { name: '🇸🇬新加坡-HY2', type: hysteria2, server: sg.example.com, port: 443, password: hy2-pwd, sni: sg.example.com }
        """
        let parser = ClashYAMLParser()

        // Verify can parse
        XCTAssertTrue(parser.canParse(yaml.data(using: .utf8)!))

        // Parse all nodes
        let nodes = try parser.parse(yaml.data(using: .utf8)!)
        XCTAssertEqual(nodes.count, 5, "Should parse all 5 proxy nodes")

        // Verify VLESS with reality
        XCTAssertEqual(nodes[0].tag, "🇭🇰香港高速01|BGP|流媒体")
        XCTAssertEqual(nodes[0].type, .vless)
        XCTAssertEqual(nodes[0].server, "aws-link1.liangxin1.xyz")
        XCTAssertEqual(nodes[0].port, 35248)

        let vlessOutbound = nodes[0].toOutbound()
        guard case .vless(let vl) = vlessOutbound else { XCTFail("Expected vless outbound"); return }
        XCTAssertEqual(vl.uuid, "13f15b9b-763b-4982-bfb6-8f1dbe1f3c06")
        XCTAssertEqual(vl.flow, "xtls-rprx-vision")
        XCTAssertNotNil(vl.unknownFields["tls"], "TLS config should be present")

        // Verify second VLESS
        XCTAssertEqual(nodes[1].tag, "🇯🇵日本高速01|BGP|流媒体")
        XCTAssertEqual(nodes[1].port, 35249)

        // Verify SS with obfs plugin
        let ssOutbound = nodes[2].toOutbound()
        guard case .shadowsocks(let ss) = ssOutbound else { XCTFail("Expected shadowsocks"); return }
        XCTAssertEqual(ss.method, "aes-128-gcm")
        XCTAssertEqual(ss.password, "Ntk2ODA2YjQ0")

        // Verify Trojan
        XCTAssertEqual(nodes[3].type, .trojan)
        let trojanOutbound = nodes[3].toOutbound()
        guard case .trojan(let t) = trojanOutbound else { XCTFail("Expected trojan"); return }
        XCTAssertEqual(t.password, "trojan-pwd-123")
        XCTAssertNotNil(t.unknownFields["tls"])

        // Verify Hysteria2
        XCTAssertEqual(nodes[4].type, .hysteria2)
        let hy2Outbound = nodes[4].toOutbound()
        guard case .hysteria2(let h) = hy2Outbound else { XCTFail("Expected hysteria2"); return }
        XCTAssertEqual(h.password, "hy2-pwd")
    }
}

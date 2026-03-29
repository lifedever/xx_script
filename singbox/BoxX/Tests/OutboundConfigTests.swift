import XCTest
@testable import BoxX

final class OutboundConfigTests: XCTestCase {

    // MARK: - Decode tests

    func testDecodeDirectOutbound() throws {
        let json = """
        {"type":"direct","tag":"DIRECT"}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .direct(let d) = outbound else { XCTFail("Expected direct"); return }
        XCTAssertEqual(d.tag, "DIRECT")
    }

    func testDecodeSelectorOutbound() throws {
        let json = """
        {"type":"selector","tag":"Proxy","outbounds":["node1","node2"],"default":"node1"}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .selector(let s) = outbound else { XCTFail("Expected selector"); return }
        XCTAssertEqual(s.tag, "Proxy")
        XCTAssertEqual(s.outbounds, ["node1", "node2"])
        XCTAssertEqual(s.default, "node1")
    }

    func testDecodeURLTestOutbound() throws {
        let json = """
        {"type":"urltest","tag":"Auto","outbounds":["node1","node2"],"url":"https://www.gstatic.com/generate_204","interval":"300s"}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .urltest(let u) = outbound else { XCTFail("Expected urltest"); return }
        XCTAssertEqual(u.tag, "Auto")
        XCTAssertEqual(u.outbounds, ["node1", "node2"])
        XCTAssertEqual(u.url, "https://www.gstatic.com/generate_204")
        XCTAssertEqual(u.interval, "300s")
    }

    func testDecodeVMessOutbound() throws {
        let json = """
        {"type":"vmess","tag":"HK-01","server":"example.com","server_port":443,"uuid":"test-uuid","alter_id":0,"security":"auto"}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .vmess(let v) = outbound else { XCTFail("Expected vmess"); return }
        XCTAssertEqual(v.tag, "HK-01")
        XCTAssertEqual(v.server, "example.com")
        XCTAssertEqual(v.serverPort, 443)
        XCTAssertEqual(v.uuid, "test-uuid")
        XCTAssertEqual(v.alterId, 0)
        XCTAssertEqual(v.security, "auto")
    }

    func testDecodeShadowsocksOutbound() throws {
        let json = """
        {"type":"shadowsocks","tag":"SS-01","server":"example.com","server_port":443,"method":"aes-128-gcm","password":"xxx"}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .shadowsocks(let s) = outbound else { XCTFail("Expected shadowsocks"); return }
        XCTAssertEqual(s.tag, "SS-01")
        XCTAssertEqual(s.server, "example.com")
        XCTAssertEqual(s.serverPort, 443)
        XCTAssertEqual(s.method, "aes-128-gcm")
        XCTAssertEqual(s.password, "xxx")
    }

    func testDecodeTrojanOutbound() throws {
        let json = """
        {"type":"trojan","tag":"TR-01","server":"example.com","server_port":443,"password":"xxx"}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .trojan(let t) = outbound else { XCTFail("Expected trojan"); return }
        XCTAssertEqual(t.tag, "TR-01")
        XCTAssertEqual(t.serverPort, 443)
        XCTAssertEqual(t.password, "xxx")
    }

    func testDecodeHysteria2Outbound() throws {
        let json = """
        {"type":"hysteria2","tag":"HY2-01","server":"example.com","server_port":443,"password":"xxx","tls":{"enabled":true}}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .hysteria2(let h) = outbound else { XCTFail("Expected hysteria2"); return }
        XCTAssertEqual(h.tag, "HY2-01")
        XCTAssertEqual(h.serverPort, 443)
        // tls should be in unknownFields
        XCTAssertNotNil(h.unknownFields["tls"])
    }

    func testDecodeVLESSOutbound() throws {
        let json = """
        {"type":"vless","tag":"VL-01","server":"example.com","server_port":443,"uuid":"xxx","flow":"xtls-rprx-vision","tls":{"enabled":true}}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .vless(let v) = outbound else { XCTFail("Expected vless"); return }
        XCTAssertEqual(v.tag, "VL-01")
        XCTAssertEqual(v.flow, "xtls-rprx-vision")
        XCTAssertNotNil(v.unknownFields["tls"])
    }

    func testDecodeUnknownOutbound() throws {
        let json = """
        {"type":"wireguard","tag":"wg0","server":"1.2.3.4","private_key":"abc"}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .unknown(let tag, let type, _) = outbound else { XCTFail("Expected unknown"); return }
        XCTAssertEqual(tag, "wg0")
        XCTAssertEqual(type, "wireguard")
    }

    // MARK: - Tag property

    func testOutboundTagProperty() throws {
        let json = """
        {"type":"direct","tag":"DIRECT"}
        """.data(using: .utf8)!
        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        XCTAssertEqual(outbound.tag, "DIRECT")
    }

    // MARK: - Round-trip tests

    func testOutboundRoundTripPreservesUnknownFields() throws {
        let json = """
        {"type":"vmess","tag":"test","server":"x.com","server_port":443,"uuid":"u","alter_id":0,"security":"auto","tls":{"enabled":true},"transport":{"type":"ws"}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Outbound.self, from: json)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(decoded)
        let redecoded = try JSONDecoder().decode(Outbound.self, from: encoded)
        guard case .vmess(let v) = redecoded else { XCTFail("Expected vmess"); return }
        XCTAssertEqual(v.tag, "test")
        XCTAssertEqual(v.serverPort, 443)
        XCTAssertNotNil(v.unknownFields["tls"])
        XCTAssertNotNil(v.unknownFields["transport"])
    }

    func testUnknownOutboundRoundTrip() throws {
        let json = """
        {"type":"wireguard","tag":"wg0","server":"1.2.3.4","private_key":"abc","peers":[{"public_key":"xyz"}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Outbound.self, from: json)
        let encoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(Outbound.self, from: encoded)
        guard case .unknown(let tag, let type, let raw) = redecoded else { XCTFail("Expected unknown"); return }
        XCTAssertEqual(tag, "wg0")
        XCTAssertEqual(type, "wireguard")
        XCTAssertNotNil(raw["private_key"])
        XCTAssertNotNil(raw["peers"])
    }

    func testDirectRoundTripPreservesType() throws {
        let json = """
        {"type":"direct","tag":"DIRECT"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Outbound.self, from: json)
        let encoded = try JSONEncoder().encode(decoded)
        let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertEqual(dict["type"] as? String, "direct")
        XCTAssertEqual(dict["tag"] as? String, "DIRECT")
    }

    func testSelectorRoundTrip() throws {
        let json = """
        {"type":"selector","tag":"Proxy","outbounds":["a","b"],"default":"a","interrupt_exist_connections":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Outbound.self, from: json)
        let encoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(Outbound.self, from: encoded)
        guard case .selector(let s) = redecoded else { XCTFail("Expected selector"); return }
        XCTAssertEqual(s.tag, "Proxy")
        XCTAssertEqual(s.outbounds, ["a", "b"])
        XCTAssertEqual(s.default, "a")
        XCTAssertNotNil(s.unknownFields["interrupt_exist_connections"])
    }
}

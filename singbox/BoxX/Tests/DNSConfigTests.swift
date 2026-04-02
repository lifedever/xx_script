// Tests/DNSConfigTests.swift
import XCTest
@testable import BoxX

final class DNSConfigTests: XCTestCase {
    var tempDir: URL!
    var engine: ConfigEngine!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Create a minimal config with dns_direct and dns_proxy servers, then deploy runtime
    private func deployWithDNSSettings(directDNS: String, proxyDNS: String) throws -> SingBoxConfig {
        // Build a config with DNS servers
        var config = SingBoxConfig(
            inbounds: [],
            outbounds: [.direct(DirectOutbound(tag: "DIRECT"))],
            route: RouteConfig()
        )
        config.dns = DNSConfig(
            servers: [
                .object([
                    "tag": .string("dns_direct"),
                    "type": .string("udp"),
                    "server": .string("223.5.5.5"),
                ]),
                .object([
                    "tag": .string("dns_proxy"),
                    "type": .string("tcp"),
                    "server": .string("1.1.1.1"),
                ]),
            ],
            rules: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configData = try encoder.encode(config)
        try configData.write(to: tempDir.appendingPathComponent("config.json"))

        // Set UserDefaults
        UserDefaults.standard.set(directDNS, forKey: "directDNS")
        UserDefaults.standard.set(proxyDNS, forKey: "proxyDNS")

        let engine = ConfigEngine(baseDir: tempDir)
        try engine.load()
        try engine.deployRuntime(skipValidation: true)

        // Read generated runtime config
        let runtimeData = try Data(contentsOf: tempDir.appendingPathComponent("runtime-config.json"))
        return try JSONDecoder().decode(SingBoxConfig.self, from: runtimeData)
    }

    /// Helper to extract DNS server dict by tag from runtime config
    private func findDNSServer(tag: String, in config: SingBoxConfig) -> [String: JSONValue]? {
        guard let servers = config.dns?.servers else { return nil }
        for server in servers {
            if case .object(let dict) = server, dict["tag"]?.stringValue == tag {
                return dict
            }
        }
        return nil
    }

    // MARK: - SNI Mapping

    func testSNIForAliDNS() {
        XCTAssertEqual(ConfigEngine.sniForIP("223.5.5.5"), "dns.alidns.com")
        XCTAssertEqual(ConfigEngine.sniForIP("223.6.6.6"), "dns.alidns.com")
    }

    func testSNIForTencentDNS() {
        XCTAssertEqual(ConfigEngine.sniForIP("1.12.12.12"), "dot.pub")
        XCTAssertEqual(ConfigEngine.sniForIP("120.53.53.53"), "dot.pub")
    }

    func testSNIForUnknownIP() {
        XCTAssertEqual(ConfigEngine.sniForIP("8.8.8.8"), "")
        XCTAssertEqual(ConfigEngine.sniForIP("1.1.1.1"), "")
    }

    // MARK: - Direct DNS: DoQ (QUIC)

    func testDirectDNS_DoQ_AliDNS() throws {
        let runtime = try deployWithDNSSettings(directDNS: "doq://223.5.5.5", proxyDNS: "tcp")
        let server = findDNSServer(tag: "dns_direct", in: runtime)

        XCTAssertNotNil(server, "dns_direct server should exist")
        XCTAssertEqual(server?["type"]?.stringValue, "quic", "DoQ should map to type 'quic'")
        XCTAssertEqual(server?["server"]?.stringValue, "223.5.5.5", "Server IP should be 223.5.5.5")

        // Verify TLS SNI
        let tls = server?["tls"]
        XCTAssertNotNil(tls, "TLS config should exist for DoQ")
        if case .object(let tlsDict) = tls {
            XCTAssertEqual(tlsDict["server_name"]?.stringValue, "dns.alidns.com", "SNI should be dns.alidns.com")
        } else {
            XCTFail("TLS should be an object")
        }
    }

    // MARK: - Direct DNS: DoH via IP

    func testDirectDNS_DoH_AliDNS() throws {
        let runtime = try deployWithDNSSettings(directDNS: "doh-ip://223.5.5.5", proxyDNS: "tcp")
        let server = findDNSServer(tag: "dns_direct", in: runtime)

        XCTAssertEqual(server?["type"]?.stringValue, "https", "DoH should map to type 'https'")
        XCTAssertEqual(server?["server"]?.stringValue, "223.5.5.5")
        if case .object(let tlsDict) = server?["tls"] {
            XCTAssertEqual(tlsDict["server_name"]?.stringValue, "dns.alidns.com")
        } else {
            XCTFail("TLS config should exist for DoH-via-IP")
        }
    }

    func testDirectDNS_DoH_Tencent() throws {
        let runtime = try deployWithDNSSettings(directDNS: "doh-ip://1.12.12.12", proxyDNS: "tcp")
        let server = findDNSServer(tag: "dns_direct", in: runtime)

        XCTAssertEqual(server?["type"]?.stringValue, "https")
        XCTAssertEqual(server?["server"]?.stringValue, "1.12.12.12")
        if case .object(let tlsDict) = server?["tls"] {
            XCTAssertEqual(tlsDict["server_name"]?.stringValue, "dot.pub")
        } else {
            XCTFail("TLS config should exist")
        }
    }

    // MARK: - Direct DNS: UDP

    func testDirectDNS_UDP() throws {
        let runtime = try deployWithDNSSettings(directDNS: "udp://223.5.5.5", proxyDNS: "tcp")
        let server = findDNSServer(tag: "dns_direct", in: runtime)

        XCTAssertEqual(server?["type"]?.stringValue, "udp")
        XCTAssertEqual(server?["server"]?.stringValue, "223.5.5.5")
        XCTAssertNil(server?["tls"], "UDP DNS should have no TLS config")
    }

    // MARK: - Direct DNS: Local

    func testDirectDNS_Local() throws {
        let runtime = try deployWithDNSSettings(directDNS: "local", proxyDNS: "tcp")
        let server = findDNSServer(tag: "dns_direct", in: runtime)

        XCTAssertEqual(server?["type"]?.stringValue, "local")
        XCTAssertNil(server?["server"], "Local DNS should have no server field")
    }

    // MARK: - Proxy DNS Types

    func testProxyDNS_TCP() throws {
        let runtime = try deployWithDNSSettings(directDNS: "udp://223.5.5.5", proxyDNS: "tcp")
        let server = findDNSServer(tag: "dns_proxy", in: runtime)

        XCTAssertEqual(server?["type"]?.stringValue, "tcp")
    }

    func testProxyDNS_UDP() throws {
        let runtime = try deployWithDNSSettings(directDNS: "udp://223.5.5.5", proxyDNS: "udp")
        let server = findDNSServer(tag: "dns_proxy", in: runtime)

        XCTAssertEqual(server?["type"]?.stringValue, "udp")
    }

    func testProxyDNS_HTTPS() throws {
        let runtime = try deployWithDNSSettings(directDNS: "udp://223.5.5.5", proxyDNS: "https")
        let server = findDNSServer(tag: "dns_proxy", in: runtime)

        XCTAssertEqual(server?["type"]?.stringValue, "https")
    }

    func testProxyDNS_QUIC() throws {
        let runtime = try deployWithDNSSettings(directDNS: "udp://223.5.5.5", proxyDNS: "quic")
        let server = findDNSServer(tag: "dns_proxy", in: runtime)

        XCTAssertEqual(server?["type"]?.stringValue, "quic")
    }

    func testProxyDNS_H3() throws {
        let runtime = try deployWithDNSSettings(directDNS: "udp://223.5.5.5", proxyDNS: "h3")
        let server = findDNSServer(tag: "dns_proxy", in: runtime)

        XCTAssertEqual(server?["type"]?.stringValue, "h3")
    }
}

// MARK: - Version Compatibility Tests

final class VersionCheckTests: XCTestCase {
    func testExactMinimumVersion() {
        XCTAssertTrue(SingBoxProcess.isVersionCompatible("1.12.0", minimum: "1.12.0"))
    }

    func testNewerPatch() {
        XCTAssertTrue(SingBoxProcess.isVersionCompatible("1.12.1", minimum: "1.12.0"))
    }

    func testNewerMinor() {
        XCTAssertTrue(SingBoxProcess.isVersionCompatible("1.13.0", minimum: "1.12.0"))
    }

    func testNewerMajor() {
        XCTAssertTrue(SingBoxProcess.isVersionCompatible("2.0.0", minimum: "1.12.0"))
    }

    func testOlderPatch() {
        // 1.11.9 < 1.12.0
        XCTAssertFalse(SingBoxProcess.isVersionCompatible("1.11.9", minimum: "1.12.0"))
    }

    func testOlderMinor() {
        XCTAssertFalse(SingBoxProcess.isVersionCompatible("1.11.0", minimum: "1.12.0"))
    }

    func testOlderMajor() {
        XCTAssertFalse(SingBoxProcess.isVersionCompatible("0.99.99", minimum: "1.12.0"))
    }

    func testMissingPatchVersion() {
        // "1.12" treated as "1.12.0"
        XCTAssertTrue(SingBoxProcess.isVersionCompatible("1.12", minimum: "1.12.0"))
    }

    func testMuchNewerVersion() {
        XCTAssertTrue(SingBoxProcess.isVersionCompatible("1.14.2", minimum: "1.12.0"))
    }
}

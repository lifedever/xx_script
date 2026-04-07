import Testing
import Foundation
@testable import ShadowProxyCore

@Test func trojanPasswordHash() {
    let hash = TrojanHeader.sha224Hex("mypassword")
    #expect(hash.count == 56)
    #expect(hash.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(hash == TrojanHeader.sha224Hex("mypassword"))  // deterministic
}

@Test func trojanRequestHeader() {
    let target = ProxyTarget(host: "example.com", port: 443)
    let header = TrojanHeader.buildRequest(password: "mypassword", target: target)
    let hashPart = String(data: header.prefix(56), encoding: .ascii)!
    #expect(hashPart == TrojanHeader.sha224Hex("mypassword"))
    #expect(header[56] == 0x0D)   // CR
    #expect(header[57] == 0x0A)   // LF
    #expect(header[58] == 0x01)   // TCP
    #expect(header[59] == 0x03)   // domain type
    #expect(header[60] == UInt8("example.com".utf8.count))
    let domainEnd = 61 + Int(header[60])
    let domain = String(data: header[61..<domainEnd], encoding: .utf8)
    #expect(domain == "example.com")
    #expect(UInt16(header[domainEnd]) << 8 | UInt16(header[domainEnd + 1]) == 443)
    #expect(header[domainEnd + 2] == 0x0D)
    #expect(header[domainEnd + 3] == 0x0A)
}

@Test func trojanRequestHeaderIPv4() {
    let target = ProxyTarget(host: "1.2.3.4", port: 80)
    let header = TrojanHeader.buildRequest(password: "test", target: target)
    #expect(header[59] == 0x01)   // IPv4
    #expect(header[60] == 1)
    #expect(header[61] == 2)
    #expect(header[62] == 3)
    #expect(header[63] == 4)
    #expect(header[64] == 0x00)
    #expect(header[65] == 80)
}

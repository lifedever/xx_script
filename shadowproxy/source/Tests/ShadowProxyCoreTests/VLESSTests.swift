import Testing
import Foundation
@testable import ShadowProxyCore

@Test func vlessRequestHeader() throws {
    let target = ProxyTarget(host: "example.com", port: 443)
    let header = try VLESSHeader.buildRequest(uuid: "ea03770f-be81-3903-b81d-19a0d0e8844f", target: target)
    #expect(header[0] == 0x00)       // version
    #expect(header[1] == 0xea)       // uuid first byte
    #expect(header[17] == 0x00)      // addons_len
    #expect(header[18] == 0x01)      // command TCP
    #expect(header[19] == 0x01)      // port 443 >> 8
    #expect(header[20] == 0xBB)      // port 443 & 0xFF
    #expect(header[21] == 0x02)      // domain type
    #expect(header[22] == UInt8("example.com".utf8.count))
    #expect(header.count == 34)      // 1+16+1+1+2+1+1+11
}

@Test func vlessRequestHeaderIPv4() throws {
    let target = ProxyTarget(host: "1.2.3.4", port: 80)
    let header = try VLESSHeader.buildRequest(uuid: "ea03770f-be81-3903-b81d-19a0d0e8844f", target: target)
    #expect(header[21] == 0x01)      // IPv4 type
    #expect(header[22] == 1)
    #expect(header[23] == 2)
    #expect(header[24] == 3)
    #expect(header[25] == 4)
    #expect(header.count == 26)      // 1+16+1+1+2+1+4
}

@Test func vlessResponseParse() {
    // Minimal response: version=0, addons_len=0
    let resp = Data([0x00, 0x00])
    #expect(VLESSHeader.parseResponse(resp) == 2)

    // Response with addons
    let resp2 = Data([0x00, 0x03, 0x01, 0x02, 0x03])
    #expect(VLESSHeader.parseResponse(resp2) == 5)

    // Incomplete
    #expect(VLESSHeader.parseResponse(Data([0x00])) == nil)
}

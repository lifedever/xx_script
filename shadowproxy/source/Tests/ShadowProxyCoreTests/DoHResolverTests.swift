import Testing
import Foundation
@testable import ShadowProxyCore

@Test func dohBuildQuery() {
    let query = DoHResolver.buildDNSQuery(domain: "example.com")
    #expect(query.count > 12)
    #expect(query[2] == 0x01) // flags
    #expect(query[3] == 0x00)
    #expect(query[4] == 0x00) // QDCOUNT
    #expect(query[5] == 0x01)
}

@Test func dohParseResponse() throws {
    var response = Data()
    // Header
    response.append(contentsOf: [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
    // Question: example.com
    response.append(contentsOf: [7])
    response.append(contentsOf: "example".utf8)
    response.append(contentsOf: [3])
    response.append(contentsOf: "com".utf8)
    response.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
    // Answer: pointer, A record, 93.184.216.34
    response.append(contentsOf: [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04])
    response.append(contentsOf: [93, 184, 216, 34])

    let ip = try DoHResolver.parseARecord(response)
    #expect(ip == "93.184.216.34")
}

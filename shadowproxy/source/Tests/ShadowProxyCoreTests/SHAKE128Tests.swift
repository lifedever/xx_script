import Testing
import Foundation
@testable import ShadowProxyCore

@Test func shake128EmptyInput() {
    var shake = SHAKE128()
    shake.absorb(Data())
    let output = shake.squeeze(count: 32)
    let hex = output.map { String(format: "%02x", $0) }.joined()
    // NIST vector: SHAKE128("") starts with 7f9c2ba4e88f827d
    #expect(hex.hasPrefix("7f9c2ba4e88f827d"))
}

@Test func shake128Abc() {
    var shake = SHAKE128()
    shake.absorb(Data("abc".utf8))
    let output = shake.squeeze(count: 16)
    let hex = output.map { String(format: "%02x", $0) }.joined()
    // NIST vector: SHAKE128("abc") starts with 5881092dd818bf5c
    #expect(hex.hasPrefix("5881092dd818bf5c"))
}

@Test func shake128StreamConsistency() {
    var shake1 = SHAKE128()
    shake1.absorb(Data("test".utf8))
    let full = shake1.squeeze(count: 32)

    var shake2 = SHAKE128()
    shake2.absorb(Data("test".utf8))
    let part1 = shake2.squeeze(count: 16)
    let part2 = shake2.squeeze(count: 16)
    #expect(full == part1 + part2)
}

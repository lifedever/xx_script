import Testing
import Foundation
import CryptoKit
@testable import ShadowProxyCore

@Test func vmessParseUUID() throws {
    let uuid = "ea03770f-be81-3903-b81d-19a0d0e8844f"
    let bytes = try VMessHeader.parseUUID(uuid)
    #expect(bytes.count == 16)
    #expect(bytes[0] == 0xea)
    #expect(bytes[1] == 0x03)
}

@Test func vmessParseInvalidUUID() {
    #expect(throws: CryptoError.self) {
        _ = try VMessHeader.parseUUID("not-a-uuid")
    }
}

@Test func vmessFNV1a32() {
    let data = Data("hello".utf8)
    let hash = VMessHeader.fnv1a32(data)
    // Known FNV1a32 hash of "hello"
    #expect(hash == 0x4f9f2cab)
}

@Test func vmessCRC32() {
    let data = Data("hello".utf8)
    let crc = VMessHeader.crc32(data)
    // Known CRC32 of "hello"
    #expect(crc == 0x3610a686)
}

@Test func vmessCmdKeyDeterministic() throws {
    let uuid = try VMessHeader.parseUUID("ea03770f-be81-3903-b81d-19a0d0e8844f")
    let key1 = VMessHeader.vmessCmdKey(uuid: uuid)
    let key2 = VMessHeader.vmessCmdKey(uuid: uuid)
    #expect(key1 == key2)
    #expect(key1.count == 16) // MD5 output
}

@Test func vmessBuildRequestProducesValidData() throws {
    let reqKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let reqIV = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

    let (header, responseKey, responseIV) = try VMessHeader.buildRequest(
        uuid: "ea03770f-be81-3903-b81d-19a0d0e8844f",
        target: ProxyTarget(host: "api.anthropic.com", port: 443),
        security: .aes128gcm,
        reqKey: reqKey,
        reqIV: reqIV
    )

    // Header should start with 16-byte authID
    #expect(header.count > 16)
    // Response key/IV should be derived from reqKey/reqIV
    #expect(responseKey.count == 16)
    #expect(responseIV.count == 16)
    #expect(responseKey != reqKey)  // SHA256 derived, should differ
}

@Test func vmessDataCipherRoundTrip() throws {
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

    var enc = VMessDataCipher(key: key, iv: iv)
    var dec = VMessDataCipher(key: key, iv: iv)

    let plaintext = Data("Hello VMess!".utf8)
    let chunk = try enc.encrypt(plaintext)

    // Chunk format: [2-byte plain length][encrypted payload (N+16 bytes)]
    #expect(chunk.count == 2 + plaintext.count + 16)

    let result = try dec.decryptChunk(from: chunk)
    #expect(result != nil)
    let (decrypted, consumed) = result!
    #expect(decrypted == plaintext)
    #expect(consumed == chunk.count)
}

@Test func vmessDataCipherMultipleChunks() throws {
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

    var enc = VMessDataCipher(key: key, iv: iv)
    var dec = VMessDataCipher(key: key, iv: iv)

    let messages = ["first message", "second message", "third message"]

    // Simulate streaming: encrypt all, concatenate, then decrypt
    var stream = Data()
    for msg in messages {
        let chunk = try enc.encrypt(Data(msg.utf8))
        stream.append(chunk)
    }

    for msg in messages {
        let result = try dec.decryptChunk(from: stream)
        #expect(result != nil)
        let (decrypted, consumed) = result!
        #expect(decrypted == Data(msg.utf8))
        stream = Data(stream.dropFirst(consumed))
    }
}

@Test func aesCFBRoundTrip() throws {
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let plaintext = Data("AES-CFB test data for VMess legacy mode".utf8)

    let encrypted = try AESCFB.encrypt(plaintext, key: key, iv: iv)
    let decrypted = try AESCFB.decrypt(encrypted, key: key, iv: iv)

    #expect(decrypted == plaintext)
    #expect(encrypted != plaintext)
    #expect(encrypted.count == plaintext.count) // CFB: same length
}

@Test func aesCFBInvalidKeyLength() {
    let key = Data([1, 2, 3]) // too short
    let iv = Data(repeating: 0, count: 16)
    #expect(throws: CryptoError.self) {
        _ = try AESCFB.encrypt(Data("test".utf8), key: key, iv: iv)
    }
}

@Test func vmessSecurityAutoResolvesToGCM() {
    let security = VMessSecurity.auto
    #expect(security.resolved == .aes128gcm)
}

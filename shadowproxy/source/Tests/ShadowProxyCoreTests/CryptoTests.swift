import Testing
import Foundation
import CryptoKit
@testable import ShadowProxyCore

// MARK: - AES-GCM Cipher Tests

@Test func aesGCMEncryptDecryptRoundTrip() throws {
    let keyData = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let key = SymmetricKey(data: keyData)

    var encCipher = AESGCMCipher(key: key)
    var decCipher = AESGCMCipher(key: key)

    let plaintext = Data("Hello, ShadowProxy!".utf8)
    let encrypted = try encCipher.encrypt(plaintext)
    let decrypted = try decCipher.decrypt(encrypted)

    #expect(decrypted == plaintext)
    #expect(encrypted != plaintext)
    #expect(encrypted.count == plaintext.count + 16) // ciphertext + 16-byte tag
}

@Test func aesGCMNonceIncrementsCorrectly() throws {
    let key = SymmetricKey(data: Data(repeating: 0xAA, count: 16))

    var enc = AESGCMCipher(key: key)
    var dec = AESGCMCipher(key: key)

    // Encrypt multiple chunks, each should use different nonce
    let data1 = Data("first".utf8)
    let data2 = Data("second".utf8)

    let enc1 = try enc.encrypt(data1)
    let enc2 = try enc.encrypt(data2)

    // Different nonces should produce different ciphertexts even for same plaintext
    #expect(enc1 != enc2 || data1 != data2)

    let dec1 = try dec.decrypt(enc1)
    let dec2 = try dec.decrypt(enc2)

    #expect(dec1 == data1)
    #expect(dec2 == data2)
}

@Test func aesGCMDecryptInvalidDataFails() throws {
    let key = SymmetricKey(data: Data(repeating: 0xBB, count: 16))
    var cipher = AESGCMCipher(key: key)

    // Too short (< 16 bytes for tag)
    #expect(throws: CryptoError.self) {
        _ = try cipher.decrypt(Data([1, 2, 3]))
    }
}

// MARK: - Key Derivation Tests

@Test func evpBytesToKeyProducesCorrectLength() {
    let key16 = ShadowsocksKeyDerivation.evpBytesToKey(password: "test-password", keyLen: 16)
    #expect(key16.count == 16)

    let key32 = ShadowsocksKeyDerivation.evpBytesToKey(password: "test-password", keyLen: 32)
    #expect(key32.count == 32)
}

@Test func evpBytesToKeyDeterministic() {
    let key1 = ShadowsocksKeyDerivation.evpBytesToKey(password: "hello", keyLen: 16)
    let key2 = ShadowsocksKeyDerivation.evpBytesToKey(password: "hello", keyLen: 16)
    #expect(key1 == key2)
}

@Test func evpBytesToKeyDifferentPasswords() {
    let key1 = ShadowsocksKeyDerivation.evpBytesToKey(password: "password1", keyLen: 16)
    let key2 = ShadowsocksKeyDerivation.evpBytesToKey(password: "password2", keyLen: 16)
    #expect(key1 != key2)
}

@Test func hkdfSHA1ProducesCorrectLength() {
    let masterKey = Data(repeating: 0xCC, count: 16)
    let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let subkey = ShadowsocksKeyDerivation.hkdfSHA1(key: masterKey, salt: salt, keyLen: 16)
    #expect(subkey.count == 16)
}

@Test func hkdfSHA1DifferentSaltsProduceDifferentKeys() {
    let masterKey = Data(repeating: 0xDD, count: 16)
    let salt1 = Data(repeating: 0x01, count: 16)
    let salt2 = Data(repeating: 0x02, count: 16)
    let subkey1 = ShadowsocksKeyDerivation.hkdfSHA1(key: masterKey, salt: salt1, keyLen: 16)
    let subkey2 = ShadowsocksKeyDerivation.hkdfSHA1(key: masterKey, salt: salt2, keyLen: 16)
    #expect(subkey1 != subkey2)
}

// MARK: - Full Shadowsocks AEAD Flow

@Test func shadowsocksAEADFullFlow() throws {
    let password = "4c028f26-e528-46c5-914a-f4872ece23d9"
    let keyLen = 16  // aes-128-gcm

    // 1. Derive master key from password
    let masterKey = ShadowsocksKeyDerivation.evpBytesToKey(password: password, keyLen: keyLen)
    #expect(masterKey.count == keyLen)

    // 2. Generate random salt
    let salt = Data((0..<keyLen).map { _ in UInt8.random(in: 0...255) })

    // 3. Derive subkey via HKDF
    let subkey = ShadowsocksKeyDerivation.hkdfSHA1(key: masterKey, salt: salt, keyLen: keyLen)
    #expect(subkey.count == keyLen)

    // 4. Encrypt with subkey
    var encCipher = AESGCMCipher(key: SymmetricKey(data: subkey))
    var decCipher = AESGCMCipher(key: SymmetricKey(data: subkey))

    let payload = Data("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\n\r\n".utf8)
    let encrypted = try encCipher.encrypt(payload)
    let decrypted = try decCipher.decrypt(encrypted)
    #expect(decrypted == payload)
}

// MARK: - ObfsHTTP Tests

@Test func obfsHTTPWrapRequest() {
    let obfs = ObfsHTTP(host: "baidu.com")
    let payload = Data("hello".utf8)
    let wrapped = obfs.wrapRequest(payload)

    let wrappedStr = String(data: wrapped, encoding: .utf8) ?? ""
    #expect(wrappedStr.hasPrefix("GET /"))
    #expect(wrappedStr.contains("Host: baidu.com"))
    #expect(wrappedStr.contains("Connection: Upgrade"))
    // Payload should be at the end
    #expect(wrapped.suffix(5) == payload)
}

@Test func obfsHTTPUnwrapResponse() {
    let obfs = ObfsHTTP(host: "baidu.com")
    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nactual-payload"
    let data = Data(response.utf8)

    let result = obfs.unwrapResponse(data)
    #expect(result != nil)
    #expect(String(data: result!.payload, encoding: .utf8) == "actual-payload")
}

@Test func obfsHTTPUnwrapIncompleteResponse() {
    let obfs = ObfsHTTP(host: "baidu.com")
    let data = Data("HTTP/1.1 200 OK\r\nPartial".utf8) // No \r\n\r\n
    let result = obfs.unwrapResponse(data)
    #expect(result == nil)
}

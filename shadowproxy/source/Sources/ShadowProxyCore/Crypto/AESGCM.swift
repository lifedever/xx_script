import Foundation
import CryptoKit

/// Shadowsocks AEAD AES-128-GCM cipher
///
/// Each encrypted chunk: [2-byte length (encrypted + 16-byte tag)][payload (encrypted + 16-byte tag)]
/// Nonce: 12 bytes, incremented after each encrypt/decrypt operation
public struct AESGCMCipher: Sendable {
    private let key: SymmetricKey
    private var nonceBytes: [UInt8]  // 12 bytes, incremented

    public init(key: SymmetricKey) {
        self.key = key
        self.nonceBytes = [UInt8](repeating: 0, count: 12)
    }

    public mutating func encrypt(_ plaintext: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        incrementNonce()
        // Rebase: sealed.ciphertext is a slice of combined (non-zero startIndex)
        return Data(sealed.ciphertext) + Data(sealed.tag)
    }

    public mutating func decrypt(_ ciphertextAndTag: Data) throws -> Data {
        guard ciphertextAndTag.count >= 16 else {
            throw CryptoError.invalidData
        }
        let ctLen = ciphertextAndTag.count - 16
        let ciphertext = ciphertextAndTag.subdata(in: ciphertextAndTag.startIndex..<(ciphertextAndTag.startIndex + ctLen))
        let tag = ciphertextAndTag.subdata(in: (ciphertextAndTag.startIndex + ctLen)..<ciphertextAndTag.endIndex)

        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        incrementNonce()
        return plaintext
    }

    private mutating func incrementNonce() {
        for i in 0..<nonceBytes.count {
            nonceBytes[i] &+= 1
            if nonceBytes[i] != 0 { break }
        }
    }
}

public enum CryptoError: Error {
    case invalidData
    case invalidKeyLength
    case hkdfFailed
}

// MARK: - Shadowsocks Key Derivation

/// Derive Shadowsocks AEAD subkey from password and salt using HKDF
/// 1. password -> key via EVP_BytesToKey (MD5-based)
/// 2. key + salt -> subkey via HKDF-SHA1
public struct ShadowsocksKeyDerivation {

    /// EVP_BytesToKey compatible key derivation from password
    /// Produces a key of `keyLen` bytes using MD5
    public static func evpBytesToKey(password: String, keyLen: Int) -> Data {
        let passwordData = Data(password.utf8)
        var key = Data()
        var prev = Data()

        while key.count < keyLen {
            var input = prev + passwordData
            prev = Data(Insecure.MD5.hash(data: input))
            key.append(prev)
            input = Data() // clear
        }

        return key.prefix(keyLen)
    }

    /// HKDF-SHA1 to derive subkey from master key + salt
    public static func hkdfSHA1(key: Data, salt: Data, info: Data = Data("ss-subkey".utf8), keyLen: Int) -> Data {
        let prk = hmacSHA1(key: salt, data: key)
        var okm = Data()
        var prev = Data()
        var counter: UInt8 = 1

        while okm.count < keyLen {
            var input = prev + info + Data([counter])
            prev = hmacSHA1(key: prk, data: input)
            okm.append(prev)
            counter += 1
            input = Data()
        }

        return okm.prefix(keyLen)
    }

    private static func hmacSHA1(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }
}

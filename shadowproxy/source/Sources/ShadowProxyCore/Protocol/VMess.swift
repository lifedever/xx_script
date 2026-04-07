import Foundation
import CryptoKit
import CommonCrypto

// MARK: - VMess AEAD Header Construction

/// VMess AEAD protocol implementation (alterId=0 mode)
///
/// Request format:
/// [auth_id (16 bytes)][encrypted_header_length (2+16 bytes)][encrypted_header (N+16 bytes)][encrypted_data...]
///
/// auth_id = HMAC-MD5(uuid_bytes, timestamp_bytes)
public struct VMessHeader: Sendable {

    /// Build VMess AEAD request header bytes
    public static func buildRequest(
        uuid: String,
        target: ProxyTarget,
        security: VMessSecurity,
        reqKey: Data,   // 16 bytes random
        reqIV: Data     // 16 bytes random
    ) throws -> (header: Data, responseKey: Data, responseIV: Data) {
        let uuidBytes = try parseUUID(uuid)
        let cmdKey = vmessCmdKey(uuid: uuidBytes)
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Auth ID: AES-ECB encrypted timestamp+crc+random with KDF-derived key
        let authID = buildAuthID(uuid: uuidBytes, timestamp: timestamp)

        // Command header (unencrypted)
        var cmd = Data()
        cmd.append(1)  // version
        cmd.append(contentsOf: reqIV)   // 16 bytes
        cmd.append(contentsOf: reqKey)  // 16 bytes
        cmd.append(UInt8.random(in: 0...255))  // response auth V
        // Option: ChunkStream only (simplest data format: plain length + GCM payload)
        cmd.append(0x01)
        let paddingLen = UInt8.random(in: 0...15)
        let secByte = (paddingLen << 4) | security.rawValue
        cmd.append(secByte)
        cmd.append(0)  // reserved
        cmd.append(0x01)  // command: TCP
        // Target port (big endian)
        cmd.append(UInt8(target.port >> 8))
        cmd.append(UInt8(target.port & 0xFF))
        // Address type + address
        cmd.append(0x02)  // domain
        let domainBytes = Data(target.host.utf8)
        cmd.append(UInt8(domainBytes.count))
        cmd.append(contentsOf: domainBytes)
        // Padding
        if paddingLen > 0 {
            cmd.append(contentsOf: (0..<paddingLen).map { _ in UInt8.random(in: 0...255) })
        }
        // FNV1a hash of command (4 bytes)
        let hash = fnv1a32(cmd)
        cmd.append(contentsOf: withUnsafeBytes(of: hash.bigEndian) { Data($0) })

        // Connection nonce (8 random bytes) — used in KDF and included in packet
        let connectionNonce = Data((0..<8).map { _ in UInt8.random(in: 0...255) })

        // Encrypt header length (2 bytes) with AES-128-GCM using KDF-derived keys
        let headerLenKey = generateHeaderLenKey(authID: authID, cmdKey: cmdKey, nonce: connectionNonce)
        let headerLenNonce = generateHeaderLenNonce(authID: authID, cmdKey: cmdKey, nonce: connectionNonce)

        var lenBytes = Data()
        lenBytes.append(UInt8(cmd.count >> 8))
        lenBytes.append(UInt8(cmd.count & 0xFF))

        let encLen = try aesGCMSeal(lenBytes, key: headerLenKey, nonce: headerLenNonce, aad: authID)

        // Encrypt header with AES-128-GCM (authID as AAD)
        let headerKey = generateHeaderKey(authID: authID, cmdKey: cmdKey, nonce: connectionNonce)
        let headerNonce = generateHeaderNonce(authID: authID, cmdKey: cmdKey, nonce: connectionNonce)
        let encHeader = try aesGCMSeal(cmd, key: headerKey, nonce: headerNonce, aad: authID)

        // Assemble: [authID][encLen][connectionNonce][encHeader]
        var result = Data()
        result.append(contentsOf: authID)
        result.append(contentsOf: encLen)
        result.append(contentsOf: connectionNonce)
        result.append(contentsOf: encHeader)

        splog.debug("VMess header: authID=\(Data(authID.prefix(4)).map{String(format:"%02x",$0)}.joined())... cmd=\(cmd.count)B opt=0x\(String(format:"%02x",cmd[34])) sec=0x\(String(format:"%02x",cmd[35])) total=\(result.count)B", tag: "VMess")

        // Response key/IV derivation
        let responseKey = Data(SHA256.hash(data: reqKey)).prefix(16)
        let responseIV = Data(SHA256.hash(data: reqIV)).prefix(16)

        return (result, Data(responseKey), Data(responseIV))
    }

    // MARK: - VMess AEAD KDF (HMAC-SHA256 chain)
    // Matches xray-core: KDF(key, path...) = HMAC chain with seed "VMess AEAD KDF"

    private static let kdfSeed = Data("VMess AEAD KDF".utf8)

    /// VMess AEAD KDF: recursive nested HMAC structure matching v2ray/sing-vmess
    ///
    /// The KDF uses nested HMACs where each level uses the parent HMAC as its inner hash function.
    /// Since Swift's CryptoKit doesn't support custom inner hash functions for HMAC,
    /// we manually implement the HMAC algorithm using the recursive hash factory.
    ///
    /// HMAC(key, data) = H(key^opad || H(key^ipad || data)) where H = parent hash function
    static func vmessKDF(_ key: Data, _ salt: Data, _ paths: [Data] = []) -> Data {
        // Build chain of hash factories: each is an HMAC that uses the parent as inner hash
        // Level 0: SHA256
        // Level 1: HMAC(key="VMess AEAD KDF", hash=SHA256)
        // Level 2: HMAC(key=salt, hash=Level1)
        // Level N+2: HMAC(key=paths[N], hash=Level N+1)
        //
        // We represent each level as a closure that hashes data

        // Level 0: plain SHA256
        var hashFunc: (Data) -> Data = { data in
            Data(SHA256.hash(data: data))
        }

        // Level 1: HMAC with key="VMess AEAD KDF", using SHA256
        hashFunc = makeHMAC(key: kdfSeed, innerHash: hashFunc)

        // Level 2: HMAC with key=salt, using Level 1
        hashFunc = makeHMAC(key: salt, innerHash: hashFunc)

        // Remaining levels
        for path in paths {
            hashFunc = makeHMAC(key: path, innerHash: hashFunc)
        }

        // Apply final hash to the input key (cmdKey)
        return hashFunc(key)
    }

    /// Manual HMAC implementation using a custom inner hash function
    /// HMAC(key, data) = H(key⊕opad ‖ H(key⊕ipad ‖ data))
    private static func makeHMAC(key: Data, innerHash: @escaping (Data) -> Data) -> (Data) -> Data {
        let blockSize = 64 // SHA256 block size

        // Pad or hash the key to blockSize
        var paddedKey: Data
        if key.count > blockSize {
            paddedKey = innerHash(key)
        } else {
            paddedKey = key
        }
        if paddedKey.count < blockSize {
            paddedKey.append(Data(repeating: 0, count: blockSize - paddedKey.count))
        }

        let ipad = Data(paddedKey.map { $0 ^ 0x36 })
        let opad = Data(paddedKey.map { $0 ^ 0x5c })

        return { data in
            let inner = innerHash(ipad + data)
            return innerHash(opad + inner)
        }
    }

    // MARK: - Auth ID

    static func buildAuthID(uuid: Data, timestamp: UInt64) -> Data {
        var tsBytes = Data(count: 8)
        for i in 0..<8 {
            tsBytes[7 - i] = UInt8((timestamp >> (i * 8)) & 0xFF)
        }
        // Order: [timestamp(8)][random(4)][CRC32 of first 12 bytes(4)]
        var msg = tsBytes
        msg.append(contentsOf: (0..<4).map { _ in UInt8.random(in: 0...255) })
        let crc = crc32(msg) // CRC32 of timestamp + random (12 bytes)
        msg.append(contentsOf: withUnsafeBytes(of: crc.bigEndian) { Data($0) })

        // AES-ECB encrypt with KDF-derived key
        let cmdKey = vmessCmdKey(uuid: uuid)
        let encKey = Data(vmessKDF(cmdKey, Data("AES Auth ID Encryption".utf8)).prefix(16))
        return aesECBEncrypt(msg, key: encKey)
    }

    // MARK: - Key Derivation

    static func vmessCmdKey(uuid: Data) -> Data {
        Data(Insecure.MD5.hash(data: uuid + Data("c48619fe-8f02-49e0-b9e9-edf763e17e21".utf8)))
    }

    static func parseUUID(_ uuid: String) throws -> Data {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { throw CryptoError.invalidData }
        var data = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else {
                throw CryptoError.invalidData
            }
            data.append(byte)
            i = next
        }
        return data
    }

    // MARK: - Header Key/Nonce Generation (KDF-based)

    static func generateHeaderLenKey(authID: Data, cmdKey: Data, nonce: Data) -> Data {
        Data(vmessKDF(cmdKey, Data("VMess Header AEAD Key_Length".utf8), [authID, nonce]).prefix(16))
    }

    static func generateHeaderLenNonce(authID: Data, cmdKey: Data, nonce: Data) -> Data {
        Data(vmessKDF(cmdKey, Data("VMess Header AEAD Nonce_Length".utf8), [authID, nonce]).prefix(12))
    }

    static func generateHeaderKey(authID: Data, cmdKey: Data, nonce: Data) -> Data {
        Data(vmessKDF(cmdKey, Data("VMess Header AEAD Key".utf8), [authID, nonce]).prefix(16))
    }

    static func generateHeaderNonce(authID: Data, cmdKey: Data, nonce: Data) -> Data {
        Data(vmessKDF(cmdKey, Data("VMess Header AEAD Nonce".utf8), [authID, nonce]).prefix(12))
    }

    // MARK: - Helpers

    static func fnv1a32(_ data: Data) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in data {
            hash ^= UInt32(byte)
            hash &*= 0x01000193
        }
        return hash
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    static func aesGCMSeal(_ data: Data, key: Data, nonce: Data, aad: Data? = nil) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let n = try AES.GCM.Nonce(data: nonce)
        let sealed: AES.GCM.SealedBox
        if let aad {
            sealed = try AES.GCM.seal(data, using: symKey, nonce: n, authenticating: aad)
        } else {
            sealed = try AES.GCM.seal(data, using: symKey, nonce: n)
        }
        return Data(sealed.ciphertext) + Data(sealed.tag)
    }

    static func aesECBEncrypt(_ data: Data, key: Data) -> Data {
        let keyArr = Array(key)
        let dataArr = Array(data)
        let outSize = data.count + kCCBlockSizeAES128
        var outArr = [UInt8](repeating: 0, count: outSize)
        var outLength = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            keyArr, keyArr.count,
            nil,
            dataArr, dataArr.count,
            &outArr, outSize,
            &outLength
        )

        guard status == kCCSuccess else {
            splog.error("AES-ECB encrypt failed: \(status)", tag: "VMess")
            return data.prefix(16)  // should never happen
        }
        return Data(outArr.prefix(outLength))
    }
}

// MARK: - VMess Security

public enum VMessSecurity: UInt8, Sendable {
    case aes128gcm = 0x03
    case chacha20poly1305 = 0x04
    case none = 0x05
    case auto = 0x00  // maps to aes128gcm on ARM

    /// Resolve "auto" to a concrete cipher
    public var resolved: VMessSecurity {
        if self == .auto { return .aes128gcm }
        return self
    }
}

// MARK: - VMess AEAD Nonce Generator

/// VMess AEAD nonce: [count_BE_2bytes][iv[2:12]]
struct VMessNonce: Sendable {
    private let ivSuffix: [UInt8]  // iv[2:12], 10 bytes
    private var count: UInt16 = 0

    init(iv: Data) {
        self.ivSuffix = Array(iv[2..<12])
    }

    mutating func next() -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = UInt8(count >> 8)
        nonce[1] = UInt8(count & 0xFF)
        for i in 0..<10 { nonce[i + 2] = ivSuffix[i] }
        count += 1
        return nonce
    }
}

/// AES-128-GCM with VMess nonce scheme
struct VMessGCM: Sendable {
    private let key: SymmetricKey
    private var nonce: VMessNonce

    init(key: Data, iv: Data) {
        self.key = SymmetricKey(data: key)
        self.nonce = VMessNonce(iv: iv)
    }

    mutating func encrypt(_ plaintext: Data) throws -> Data {
        let n = try AES.GCM.Nonce(data: nonce.next())
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: n)
        // Rebase: sealed.ciphertext is a slice of combined (startIndex=12), must copy
        return Data(sealed.ciphertext) + Data(sealed.tag)
    }

    mutating func decrypt(_ ciphertextAndTag: Data) throws -> Data {
        guard ciphertextAndTag.count >= 16 else { throw CryptoError.invalidData }
        let ctLen = ciphertextAndTag.count - 16
        let ct = ciphertextAndTag.subdata(in: ciphertextAndTag.startIndex..<(ciphertextAndTag.startIndex + ctLen))
        let tag = ciphertextAndTag.subdata(in: (ciphertextAndTag.startIndex + ctLen)..<ciphertextAndTag.endIndex)
        let n = try AES.GCM.Nonce(data: nonce.next())
        let box = try AES.GCM.SealedBox(nonce: n, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: key)
    }
}

// MARK: - VMess Data Cipher

/// VMess AEAD chunk-based data encryption/decryption
///
/// Each chunk on wire:
///   [encrypted 2-byte length (2+16=18 bytes)][encrypted payload (N+16 bytes)]
///
/// Length and payload use separate GCM ciphers with VMess nonce scheme
public struct VMessDataCipher: Sendable {
    private var dataCipher: VMessGCM

    public init(key: Data, iv: Data, security: VMessSecurity = .aes128gcm) {
        // Data cipher uses key directly with VMess nonce scheme
        self.dataCipher = VMessGCM(key: key, iv: iv)
    }

    /// Encrypt plaintext into a VMess chunk: [2-byte BE length of encrypted][GCM encrypted payload]
    public mutating func encrypt(_ plaintext: Data) throws -> Data {
        let encPayload = try dataCipher.encrypt(plaintext)

        // Plain 2-byte length (big-endian) of the encrypted payload
        let encLen = UInt16(encPayload.count)
        var chunk = Data([UInt8(encLen >> 8), UInt8(encLen & 0xFF)])
        chunk.append(encPayload)
        return chunk
    }

    /// Decrypt a single chunk from buffer. Returns (plaintext, bytesConsumed) or nil if not enough data.
    public mutating func decryptChunk(from buffer: Data) throws -> (Data, Int)? {
        // Need at least 2 bytes for length
        guard buffer.count >= 2 else { return nil }

        // Read plain 2-byte length
        let encPayloadLen = Int(UInt16(buffer[buffer.startIndex]) << 8 | UInt16(buffer[buffer.startIndex + 1]))
        guard encPayloadLen > 0 else { return (Data(), 2) } // zero = end of stream

        let totalChunkSize = 2 + encPayloadLen
        guard buffer.count >= totalChunkSize else { return nil }

        // Decrypt payload
        let encPayload = Data(buffer[(buffer.startIndex + 2)..<(buffer.startIndex + totalChunkSize)])
        let plaintext = try dataCipher.decrypt(encPayload)

        return (plaintext, totalChunkSize)
    }
}

// MARK: - VMess Response Header

public struct VMessResponse {
    /// Decrypt VMess AEAD response header from buffer
    /// Format: [AEAD encrypted 2-byte length (18 bytes)][AEAD encrypted header (N+16 bytes)]
    /// Returns (header bytes, total bytes consumed) or nil if not enough data
    public static func decryptHeader(_ buffer: Data, responseKey: Data, responseIV: Data) throws -> (Data, Int)? {
        // Need at least 18 bytes for encrypted length
        guard buffer.count >= 18 else { return nil }

        // Decrypt length
        let lenKey = Data(VMessHeader.vmessKDF(responseKey, Data("AEAD Resp Header Len Key".utf8)).prefix(16))
        let lenNonce = Data(VMessHeader.vmessKDF(responseIV, Data("AEAD Resp Header Len IV".utf8)).prefix(12))

        let encLenData = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + 18))
        let ct1 = encLenData.subdata(in: encLenData.startIndex..<(encLenData.startIndex + 2))
        let tag1 = encLenData.subdata(in: (encLenData.startIndex + 2)..<encLenData.endIndex)
        let box1 = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: lenNonce),
            ciphertext: ct1, tag: tag1
        )
        let lenBytes = try AES.GCM.open(box1, using: SymmetricKey(data: lenKey))
        let headerLen = Int(UInt16(lenBytes[0]) << 8 | UInt16(lenBytes[1]))

        // Check if we have enough for the encrypted header
        let totalNeeded = 18 + headerLen + 16
        guard buffer.count >= totalNeeded else { return nil }

        // Decrypt header
        let headerKey = Data(VMessHeader.vmessKDF(responseKey, Data("AEAD Resp Header Key".utf8)).prefix(16))
        let headerNonce = Data(VMessHeader.vmessKDF(responseIV, Data("AEAD Resp Header IV".utf8)).prefix(12))

        let encHeader = buffer.subdata(in: (buffer.startIndex + 18)..<(buffer.startIndex + totalNeeded))
        let ct2 = encHeader.subdata(in: encHeader.startIndex..<(encHeader.startIndex + headerLen))
        let tag2 = encHeader.subdata(in: (encHeader.startIndex + headerLen)..<encHeader.endIndex)
        let box2 = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: headerNonce),
            ciphertext: ct2, tag: tag2
        )
        let header = try AES.GCM.open(box2, using: SymmetricKey(data: headerKey))

        return (header, totalNeeded)
    }
}

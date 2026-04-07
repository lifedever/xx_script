import Foundation
import Network
import CryptoKit

/// Bidirectional data relay between client and remote connections
/// Forwards data in both directions until either side closes or errors
public struct Relay {

    /// Start bidirectional relay between client and remote connections
    /// Returns when either connection closes or an error occurs
    public static func bridge(
        client: NWConnection,
        remote: NWConnection
    ) async {
        await withTaskGroup(of: Void.self) { group in
            // Client → Remote
            group.addTask {
                await forward(from: client, to: remote)
            }
            // Remote → Client
            group.addTask {
                await forward(from: remote, to: client)
            }
            // When either direction finishes, cancel both
            await group.next()
            client.cancel()
            remote.cancel()
            group.cancelAll()
        }
    }

    /// Forward data from source to destination until EOF or error
    private static func forward(from source: NWConnection, to dest: NWConnection) async {
        while true {
            do {
                let data = try await receiveData(from: source)
                guard !data.isEmpty else { return } // EOF
                try await sendData(data, to: dest)
            } catch {
                return
            }
        }
    }

    // MARK: - Shadowsocks AEAD Bridge

    /// Bidirectional relay with SS AEAD encryption/decryption
    /// - encryptCipher: used to encrypt client→remote data (already initialized with correct nonce state)
    /// - masterKey: used to derive decryption subkey from server's salt
    /// - keyLen: key length for the cipher method
    public static func shadowsocksBridge(
        client: NWConnection,
        remote: NWConnection,
        encryptCipher: AESGCMCipher,
        masterKey: Data,
        keyLen: Int,
        obfsHost: String? = nil
    ) async {
        await withTaskGroup(of: Void.self) { group in
            // Client → Remote: read plaintext, encrypt as AEAD chunks
            group.addTask {
                var cipher = encryptCipher
                await ssEncryptForward(from: client, to: remote, cipher: &cipher)
            }
            // Remote → Client: read AEAD chunks, decrypt, forward plaintext
            group.addTask {
                await ssDecryptForward(from: remote, to: client, masterKey: masterKey, keyLen: keyLen, obfsHost: obfsHost)
            }
            await group.next()
            client.cancel()
            remote.cancel()
            group.cancelAll()
        }
    }

    /// Read plaintext from source, encrypt as SS AEAD chunks, send to dest
    private static func ssEncryptForward(
        from source: NWConnection,
        to dest: NWConnection,
        cipher: inout AESGCMCipher
    ) async {
        while true {
            do {
                let data = try await receiveData(from: source)
                guard !data.isEmpty else { return }

                // Split into max 0x3FFF byte chunks (SS AEAD max payload size)
                var offset = 0
                while offset < data.count {
                    let chunkSize = min(data.count - offset, 0x3FFF)
                    let chunk = data[offset..<(offset + chunkSize)]

                    // [encrypted length (2 bytes + 16 tag)][encrypted payload (N bytes + 16 tag)]
                    let len = UInt16(chunkSize)
                    var lenData = Data()
                    lenData.append(UInt8(len >> 8))
                    lenData.append(UInt8(len & 0xFF))
                    let encLen = try cipher.encrypt(lenData)
                    let encPayload = try cipher.encrypt(Data(chunk))

                    var frame = encLen
                    frame.append(encPayload)
                    try await sendData(frame, to: dest)

                    offset += chunkSize
                }
            } catch {
                splog.error("SS encrypt error: \(error)", tag: "Relay")
                return
            }
        }
    }

    /// Read SS AEAD response from source (salt + encrypted chunks), decrypt, forward to dest
    ///
    /// Server response format: [salt (keyLen bytes)][chunk1][chunk2]...
    /// Each chunk: [encrypted 2-byte length + 16-byte tag][encrypted payload + 16-byte tag]
    private static func ssDecryptForward(
        from source: NWConnection,
        to dest: NWConnection,
        masterKey: Data,
        keyLen: Int,
        obfsHost: String? = nil
    ) async {
        var buffer = Data()
        var decryptCipher: AESGCMCipher?
        var pendingPayloadLen: Int?
        var obfsStripped = (obfsHost == nil) // If no obfs, consider it already stripped

        while true {
            do {
                let data = try await receiveData(from: source)
                guard !data.isEmpty else {
                    splog.debug("SS decrypt: EOF from remote", tag: "Relay")
                    return
                }
                buffer.append(data)
                splog.debug("SS decrypt: received \(data.count) bytes, buffer=\(buffer.count)", tag: "Relay")
                // Log first response raw bytes for debugging
                if decryptCipher == nil && !obfsStripped {
                    if let str = String(data: buffer.prefix(min(buffer.count, 500)), encoding: .utf8) {
                        splog.debug("SS decrypt: raw response (\(buffer.count)b): \(str.replacingOccurrences(of: "\r\n", with: "\\r\\n"))", tag: "Relay")
                    }
                }

                // Strip obfs-http response header from first response
                if !obfsStripped {
                    if let obfsHost {
                        let obfs = ObfsHTTP(host: obfsHost)
                        guard let result = obfs.unwrapResponse(buffer) else {
                            splog.debug("SS decrypt: waiting for obfs HTTP header, buffer=\(buffer.count)", tag: "Relay")
                            continue // Need more data to find \r\n\r\n
                        }
                        splog.debug("SS decrypt: obfs stripped, payload=\(result.payload.count) bytes", tag: "Relay")
                        buffer = result.payload
                        obfsStripped = true
                    }
                }

                // First response after obfs strip: parse salt and initialize decrypt cipher
                if decryptCipher == nil {
                    guard buffer.count >= keyLen else { continue }
                    let salt = buffer.prefix(keyLen)
                    buffer = Data(buffer.dropFirst(keyLen))
                    splog.debug("SS decrypt: salt parsed, remaining buffer=\(buffer.count)", tag: "Relay")
                    let subkey = ShadowsocksKeyDerivation.hkdfSHA1(
                        key: masterKey, salt: salt, keyLen: keyLen
                    )
                    decryptCipher = AESGCMCipher(key: SymmetricKey(data: subkey))
                }

                guard var cipher = decryptCipher else { continue }

                // Decrypt as many complete chunks as possible
                var madeProgress = true
                while madeProgress {
                    madeProgress = false

                    if let payloadLen = pendingPayloadLen {
                        // We already decrypted the length, waiting for payload
                        guard buffer.count >= payloadLen + 16 else { break }
                        let encPayload = Data(buffer.prefix(payloadLen + 16))
                        buffer = Data(buffer.dropFirst(payloadLen + 16))
                        pendingPayloadLen = nil

                        let plaintext = try cipher.decrypt(encPayload)
                        try await sendData(plaintext, to: dest)
                        madeProgress = true
                    } else {
                        // Need to decrypt length first
                        guard buffer.count >= 2 + 16 else { break }
                        let encLenChunk = Data(buffer.prefix(2 + 16))
                        buffer = Data(buffer.dropFirst(2 + 16))

                        let lenData = try cipher.decrypt(encLenChunk)
                        let payloadLen = Int(UInt16(lenData[0]) << 8 | UInt16(lenData[1]))

                        // Check if payload is already available
                        if buffer.count >= payloadLen + 16 {
                            let encPayload = Data(buffer.prefix(payloadLen + 16))
                            buffer = Data(buffer.dropFirst(payloadLen + 16))

                            let plaintext = try cipher.decrypt(encPayload)
                            try await sendData(plaintext, to: dest)
                            madeProgress = true
                        } else {
                            // Save pending state, wait for more data
                            pendingPayloadLen = payloadLen
                        }
                    }
                }

                decryptCipher = cipher

            } catch {
                splog.error("SS decrypt error: \(error)", tag: "Relay")
                return
            }
        }
    }

    // MARK: - VMess AEAD Bridge

    /// Bidirectional VMess AEAD relay
    public static func vmessBridge(
        client: NWConnection,
        remote: NWConnection,
        encryptCipher: VMessDataCipher,
        responseKey: Data,
        responseIV: Data
    ) async {
        await withTaskGroup(of: Void.self) { group in
            // Client → Remote: read plaintext, encrypt as VMess chunks
            group.addTask {
                var cipher = encryptCipher
                await vmessEncryptForward(from: client, to: remote, cipher: &cipher)
            }
            // Remote → Client: decrypt response header + VMess chunks
            group.addTask {
                await vmessDecryptForward(from: remote, to: client, responseKey: responseKey, responseIV: responseIV)
            }
            await group.next()
            client.cancel()
            remote.cancel()
            group.cancelAll()
        }
    }

    private static func vmessEncryptForward(
        from source: NWConnection,
        to dest: NWConnection,
        cipher: inout VMessDataCipher
    ) async {
        while true {
            do {
                let data = try await receiveData(from: source)
                guard !data.isEmpty else { return }
                let chunk = try cipher.encrypt(data)
                try await sendData(chunk, to: dest)
            } catch {
                splog.error("VMess encrypt error: \(error)", tag: "Relay")
                return
            }
        }
    }

    private static func vmessDecryptForward(
        from source: NWConnection,
        to dest: NWConnection,
        responseKey: Data,
        responseIV: Data
    ) async {
        var buffer = Data()
        var responseParsed = false
        var decryptCipher: VMessDataCipher?

        while true {
            do {
                let data = try await receiveData(from: source)
                guard !data.isEmpty else {
                    splog.debug("VMess decrypt: EOF from remote", tag: "Relay")
                    return
                }
                buffer.append(data)
                splog.debug("VMess decrypt: received \(data.count) bytes, buffer=\(buffer.count)", tag: "Relay")

                // First: parse response header [AEAD enc length (18)][AEAD enc header (N+16)]
                if !responseParsed {
                    guard buffer.count >= 18 else { continue }
                    do {
                        guard let (respHeader, consumed) = try VMessResponse.decryptHeader(buffer, responseKey: responseKey, responseIV: responseIV) else {
                            continue // need more data
                        }
                        buffer = Data(buffer.dropFirst(consumed))
                        responseParsed = true
                        splog.debug("VMess response header OK (\(consumed)B): \(respHeader.map { String(format: "%02x", $0) }.joined())", tag: "Relay")
                        // Initialize data decryption cipher with responseKey/IV
                        decryptCipher = VMessDataCipher(key: responseKey, iv: responseIV)
                    } catch {
                        splog.error("VMess response header decrypt failed: \(error)", tag: "Relay")
                        return
                    }
                }

                guard var cipher = decryptCipher else { continue }

                // Decrypt data chunks
                var madeProgress = true
                while madeProgress {
                    madeProgress = false

                    if let result = try cipher.decryptChunk(from: buffer) {
                        let (plaintext, consumed) = result
                        buffer = Data(buffer.dropFirst(consumed))
                        if plaintext.isEmpty {
                            // Zero-length chunk = end of stream
                            return
                        }
                        try await sendData(plaintext, to: dest)
                        madeProgress = true
                    }
                    // else: not enough data, wait for more
                }

                decryptCipher = cipher

            } catch {
                splog.error("VMess decrypt error: \(error)", tag: "Relay")
                return
            }
        }
    }

    static func receiveData(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    static func sendData(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

// MARK: - NWConnection async helpers

extension NWConnection {
    /// Connect and wait for ready state
    func connectAsync(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    self.stateUpdateHandler = nil
                    continuation.resume(throwing: NWError.posix(.ECANCELED))
                default:
                    break
                }
            }
            self.start(queue: queue)
        }
    }
}

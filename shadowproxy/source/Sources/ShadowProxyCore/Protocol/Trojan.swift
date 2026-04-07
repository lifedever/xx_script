import Foundation
import CommonCrypto

/// Trojan protocol — disguises as normal HTTPS, forced TLS
/// Request: [sha224_hex(56)][CRLF][cmd(1)][addr_type(1)][addr(N)][port(2)][CRLF]
/// No response header — data starts immediately
public struct TrojanHeader: Sendable {

    public static func sha224Hex(_ password: String) -> String {
        let data = Data(password.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA224(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public static func buildRequest(password: String, target: ProxyTarget) -> Data {
        var header = Data()
        header.append(contentsOf: Data(sha224Hex(password).utf8))  // 56 bytes
        header.append(contentsOf: [0x0D, 0x0A])                   // CRLF
        header.append(0x01)                                         // TCP CONNECT
        appendSOCKS5Address(target.host, to: &header)
        header.append(UInt8(target.port >> 8))
        header.append(UInt8(target.port & 0xFF))
        header.append(contentsOf: [0x0D, 0x0A])                   // CRLF
        return header
    }

    private static func appendSOCKS5Address(_ host: String, to data: inout Data) {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            data.append(0x01)  // IPv4
            for part in parts { data.append(UInt8(part)!) }
            return
        }
        let domainBytes = Data(host.utf8)
        data.append(0x03)  // Domain
        data.append(UInt8(domainBytes.count))
        data.append(contentsOf: domainBytes)
    }
}

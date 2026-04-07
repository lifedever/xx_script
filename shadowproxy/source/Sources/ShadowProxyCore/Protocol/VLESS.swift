import Foundation

/// VLESS protocol — no encryption, relies entirely on TLS transport
/// Request: [version(1)][uuid(16)][addons_len(1)][command(1)][port(2)][addr_type(1)][addr(N)]
/// Response: [version(1)][addons_len(1)][addons(N)]
public struct VLESSHeader: Sendable {

    public static func buildRequest(uuid: String, target: ProxyTarget) throws -> Data {
        let uuidBytes = try VMessHeader.parseUUID(uuid)
        var header = Data()
        header.append(0x00)                          // version
        header.append(contentsOf: uuidBytes)          // uuid 16 bytes
        header.append(0x00)                          // addons_len = 0
        header.append(0x01)                          // command = TCP
        header.append(UInt8(target.port >> 8))        // port big-endian
        header.append(UInt8(target.port & 0xFF))
        appendAddress(target.host, to: &header)
        return header
    }

    public static func parseResponse(_ buffer: Data) -> Int? {
        guard buffer.count >= 2 else { return nil }
        let addonsLen = Int(buffer[buffer.startIndex + 1])
        let totalLen = 2 + addonsLen
        guard buffer.count >= totalLen else { return nil }
        return totalLen
    }

    private static func appendAddress(_ host: String, to data: inout Data) {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            data.append(0x01)  // IPv4
            for part in parts { data.append(UInt8(part)!) }
            return
        }
        let domainBytes = Data(host.utf8)
        data.append(0x02)  // Domain
        data.append(UInt8(domainBytes.count))
        data.append(contentsOf: domainBytes)
    }
}

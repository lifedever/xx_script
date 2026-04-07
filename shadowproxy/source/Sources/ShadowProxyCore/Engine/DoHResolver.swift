import Foundation

/// DNS-over-HTTPS resolver (RFC 8484)
/// Used only for DIRECT connections to avoid system DNS leaks
public final class DoHResolver: @unchecked Sendable {
    private let serverURL: String
    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    private struct CacheEntry {
        let ip: String
        let expiry: Date
    }

    public init(server: String = "https://223.5.5.5/dns-query") {
        self.serverURL = server
    }

    public func resolve(_ domain: String) async throws -> String {
        if let cached = getCached(domain) {
            return cached
        }

        let query = Self.buildDNSQuery(domain: domain)
        let base64Query = query.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        guard let url = URL(string: "\(serverURL)?dns=\(base64Query)") else {
            throw DoHError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5

        let (data, _) = try await URLSession.shared.data(for: request)
        let ip = try Self.parseARecord(data)

        setCache(domain, ip: ip)

        return ip
    }

    private func getCached(_ domain: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let entry = cache[domain], entry.expiry > Date() {
            return entry.ip
        }
        return nil
    }

    private func setCache(_ domain: String, ip: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[domain] = CacheEntry(ip: ip, expiry: Date().addingTimeInterval(300))
    }

    /// Build DNS query packet for A record
    static func buildDNSQuery(domain: String) -> Data {
        var query = Data()
        let txID = UInt16.random(in: 0...0xFFFF)
        query.append(UInt8(txID >> 8))
        query.append(UInt8(txID & 0xFF))
        query.append(contentsOf: [0x01, 0x00]) // flags: recursion desired
        query.append(contentsOf: [0x00, 0x01]) // QDCOUNT=1
        query.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // AN/NS/AR=0

        for label in domain.split(separator: ".") {
            let bytes = Data(label.utf8)
            query.append(UInt8(bytes.count))
            query.append(contentsOf: bytes)
        }
        query.append(0x00) // root
        query.append(contentsOf: [0x00, 0x01]) // QTYPE=A
        query.append(contentsOf: [0x00, 0x01]) // QCLASS=IN
        return query
    }

    /// Parse first A record from DNS response
    static func parseARecord(_ data: Data) throws -> String {
        guard data.count >= 12 else { throw DoHError.invalidResponse }
        var offset = 12

        let qdCount = Int(UInt16(data[4]) << 8 | UInt16(data[5]))
        for _ in 0..<qdCount {
            offset = try skipDNSName(data, offset: offset)
            offset += 4
        }

        let anCount = Int(UInt16(data[6]) << 8 | UInt16(data[7]))
        for _ in 0..<anCount {
            offset = try skipDNSName(data, offset: offset)
            guard offset + 10 <= data.count else { throw DoHError.invalidResponse }
            let rdType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let rdLength = Int(UInt16(data[offset + 8]) << 8 | UInt16(data[offset + 9]))
            offset += 10
            if rdType == 1 && rdLength == 4 {
                guard offset + 4 <= data.count else { throw DoHError.invalidResponse }
                return "\(data[offset]).\(data[offset+1]).\(data[offset+2]).\(data[offset+3])"
            }
            offset += rdLength
        }
        throw DoHError.noARecord
    }

    private static func skipDNSName(_ data: Data, offset: Int) throws -> Int {
        var pos = offset
        while pos < data.count {
            let len = Int(data[pos])
            if len == 0 { return pos + 1 }
            if len & 0xC0 == 0xC0 { return pos + 2 }
            pos += 1 + len
        }
        throw DoHError.invalidResponse
    }
}

public enum DoHError: Error {
    case invalidURL
    case invalidResponse
    case noARecord
}

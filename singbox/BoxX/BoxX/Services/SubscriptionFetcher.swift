// BoxX/Services/SubscriptionFetcher.swift
import Foundation

struct SubscriptionInfo: Sendable {
    let upload: Int64       // bytes uploaded
    let download: Int64     // bytes downloaded
    let total: Int64        // total bytes allowed
    let expire: Date?       // expiry timestamp (nil = never)

    var used: Int64 { upload + download }
    var remaining: Int64 { max(0, total - used) }
    var usagePercent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }

    /// Format bytes to human-readable string
    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }
}

struct FetchResult: Sendable {
    let data: Data
    let info: SubscriptionInfo?
}

struct SubscriptionFetcher: Sendable {
    func fetch(url: URL) async throws -> FetchResult {
        var request = URLRequest(url: url)
        request.setValue("clash-verge/v2.0.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SubscriptionFetchError.httpError(statusCode: statusCode)
        }

        let info = parseUserInfo(httpResponse.value(forHTTPHeaderField: "subscription-userinfo"))
        return FetchResult(data: data, info: info)
    }

    private func parseUserInfo(_ header: String?) -> SubscriptionInfo? {
        guard let header, !header.isEmpty else { return nil }
        var upload: Int64 = 0
        var download: Int64 = 0
        var total: Int64 = 0
        var expire: Date? = nil

        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let kv = trimmed.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let val = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "upload": upload = Int64(val) ?? 0
            case "download": download = Int64(val) ?? 0
            case "total": total = Int64(val) ?? 0
            case "expire":
                if let ts = TimeInterval(val), ts > 0 {
                    expire = Date(timeIntervalSince1970: ts)
                }
            default: break
            }
        }
        return SubscriptionInfo(upload: upload, download: download, total: total, expire: expire)
    }
}

enum SubscriptionFetchError: Error, LocalizedError {
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP error: \(code)"
        }
    }
}

// BoxX/Services/SubscriptionFetcher.swift
import Foundation

struct SubscriptionFetcher: Sendable {
    func fetch(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("clash-verge/v2.0.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SubscriptionFetchError.httpError(statusCode: statusCode)
        }
        return data
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

// BoxX/Services/RuleSetManager.swift
import Foundation

class RuleSetManager {
    let rulesDir: URL
    let proxyPort: Int

    init(rulesDir: URL, proxyPort: Int = 7890) {
        self.rulesDir = rulesDir
        self.proxyPort = proxyPort
    }

    private lazy var proxySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: proxyPort,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort: proxyPort,
        ]
        return URLSession(configuration: config)
    }()

    private lazy var directSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Download a remote rule set file and cache locally.
    /// Tries local proxy first, falls back to direct connection.
    func downloadRuleSet(url: URL, filename: String) async throws -> URL {
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        let destination = rulesDir.appendingPathComponent(filename)

        // Try proxy first, then direct
        let data: Data
        do {
            data = try await download(url: url, session: proxySession)
        } catch {
            data = try await download(url: url, session: directSession)
        }

        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func download(url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RuleSetError.downloadFailed(url: url)
        }
        return data
    }

    /// Check if a cached rule set exists and is fresh (within the given interval)
    func isCached(filename: String, maxAge: TimeInterval = 86400) -> Bool {
        let file = rulesDir.appendingPathComponent(filename)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modDate) < maxAge
    }

    /// Get local path for a cached rule set
    func cachedPath(filename: String) -> URL {
        rulesDir.appendingPathComponent(filename)
    }
}

enum RuleSetError: Error, LocalizedError {
    case downloadFailed(url: URL)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let url): return "Failed to download rule set from \(url)"
        }
    }
}

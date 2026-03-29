// BoxX/Services/RuleSetManager.swift
import Foundation

class RuleSetManager {
    let rulesDir: URL

    init(rulesDir: URL) {
        self.rulesDir = rulesDir
    }

    /// Download a remote rule set file and cache locally
    func downloadRuleSet(url: URL, filename: String) async throws -> URL {
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        let destination = rulesDir.appendingPathComponent(filename)

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RuleSetError.downloadFailed(url: url)
        }

        try data.write(to: destination, options: .atomic)
        return destination
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

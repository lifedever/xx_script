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
    /// Automatically converts .txt and .json formats to .srs binary format.
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

        let urlPath = url.path.lowercased()
        if urlPath.hasSuffix(".txt") {
            // Text domain list → convert to sing-box JSON rule-set → compile to SRS
            print("[BoxX] Rule set \(filename): converting .txt (\(data.count) bytes) → JSON → SRS")
            let jsonData = try Self.convertTxtToRuleSetJSON(data)
            print("[BoxX] Rule set \(filename): JSON generated (\(jsonData.count) bytes), compiling to SRS...")
            let srsData = try await Self.compileToSRS(jsonData: jsonData, rulesDir: rulesDir)
            try srsData.write(to: destination, options: .atomic)
            print("[BoxX] Rule set \(filename): SRS compiled (\(srsData.count) bytes) ✅")
        } else if urlPath.hasSuffix(".json") && !filename.hasSuffix(".json") {
            // JSON rule-set → compile to SRS
            print("[BoxX] Rule set \(filename): converting .json → SRS")
            let srsData = try await Self.compileToSRS(jsonData: data, rulesDir: rulesDir)
            try srsData.write(to: destination, options: .atomic)
            print("[BoxX] Rule set \(filename): SRS compiled (\(srsData.count) bytes) ✅")
        } else {
            // .srs or other binary → save directly
            try data.write(to: destination, options: .atomic)
            print("[BoxX] Rule set \(filename): saved directly (\(data.count) bytes) ✅")
        }

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

    // MARK: - Format Conversion

    /// Convert Loyalsoldier-style text domain list to sing-box JSON rule-set format.
    /// Supports prefixes: full: (exact domain), regexp: (regex), keyword: (keyword), plain (domain_suffix)
    static func convertTxtToRuleSetJSON(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuleSetError.conversionFailed("Cannot decode text data as UTF-8")
        }

        var domains: [String] = []
        var domainSuffixes: [String] = []
        var domainKeywords: [String] = []
        var domainRegexes: [String] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("full:") {
                domains.append(String(trimmed.dropFirst(5)))
            } else if trimmed.hasPrefix("regexp:") {
                domainRegexes.append(String(trimmed.dropFirst(7)))
            } else if trimmed.hasPrefix("keyword:") {
                domainKeywords.append(String(trimmed.dropFirst(8)))
            } else {
                domainSuffixes.append(trimmed)
            }
        }

        var rule: [String: Any] = [:]
        if !domains.isEmpty { rule["domain"] = domains.sorted() }
        if !domainSuffixes.isEmpty { rule["domain_suffix"] = domainSuffixes.sorted() }
        if !domainKeywords.isEmpty { rule["domain_keyword"] = domainKeywords.sorted() }
        if !domainRegexes.isEmpty { rule["domain_regex"] = domainRegexes.sorted() }

        let ruleSet: [String: Any] = [
            "version": 2,
            "rules": rule.isEmpty ? [] : [rule]
        ]

        return try JSONSerialization.data(withJSONObject: ruleSet, options: [.sortedKeys])
    }

    /// Compile JSON rule-set to SRS binary format using sing-box CLI
    static func compileToSRS(jsonData: Data, rulesDir: URL) async throws -> Data {
        let tmpJSON = rulesDir.appendingPathComponent("_convert_tmp.json")
        let tmpSRS = rulesDir.appendingPathComponent("_convert_tmp.srs")

        defer {
            try? FileManager.default.removeItem(at: tmpJSON)
            try? FileManager.default.removeItem(at: tmpSRS)
        }

        try jsonData.write(to: tmpJSON, options: .atomic)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")
        proc.arguments = ["rule-set", "compile", tmpJSON.path, "-o", tmpSRS.path]
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw RuleSetError.conversionFailed("sing-box rule-set compile failed: \(errMsg)")
        }

        return try Data(contentsOf: tmpSRS)
    }
}

enum RuleSetError: Error, LocalizedError {
    case downloadFailed(url: URL)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let url): return "下载规则集失败: \(url)"
        case .conversionFailed(let msg): return "规则集转换失败: \(msg)"
        }
    }
}

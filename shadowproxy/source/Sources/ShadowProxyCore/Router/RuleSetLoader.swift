import Foundation

public struct RuleSetLoader {
    private let cacheDir: String

    public init(cacheDir: String = NSHomeDirectory() + "/.shadowproxy/rulesets") {
        self.cacheDir = cacheDir
    }

    /// 下载并解析远程 .list 规则文件，返回 [url: [Rule]]
    public func loadAll(ruleSets: [(url: String, policy: String)]) async -> [String: [Rule]] {
        var result: [String: [Rule]] = [:]

        for (url, _) in ruleSets {
            let rules = await load(url: url)
            result[url] = rules
        }

        return result
    }

    /// 下载单个 .list 文件，解析为 Rule 数组（policy 为空，由调用方覆盖）
    public func load(url urlString: String) async -> [Rule] {
        // 先检查缓存
        let cacheFile = cacheFilePath(for: urlString)
        if let cached = loadFromCache(cacheFile) {
            return cached
        }

        // 下载
        guard let url = URL(string: urlString) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let content = String(data: data, encoding: .utf8) else { return [] }

            // 缓存到本地
            saveToCache(content, path: cacheFile)

            return parseList(content)
        } catch {
            return []
        }
    }

    /// 解析 .list 格式内容
    func parseList(_ content: String) -> [Rule] {
        var rules: [Rule] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }

            let ruleType = parts[0].uppercased()
            let value = parts[1]
            // policy 留空，由 Router 初始化时根据 RULE-SET 的 policy 覆盖
            let policy = ""

            switch ruleType {
            case "DOMAIN-SUFFIX": rules.append(.domainSuffix(value, policy))
            case "DOMAIN":        rules.append(.domain(value, policy))
            case "IP-CIDR":       rules.append(.ipCIDR(value, policy))
            default: break
            }
        }
        return rules
    }

    private func cacheFilePath(for url: String) -> String {
        let filename = url.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cacheDir + "/" + filename
    }

    private func loadFromCache(_ path: String) -> [Rule]? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attr[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < 3600 else {
            return nil
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return parseList(content)
    }

    private func saveToCache(_ content: String, path: String) {
        try? FileManager.default.createDirectory(
            atPath: cacheDir,
            withIntermediateDirectories: true
        )
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

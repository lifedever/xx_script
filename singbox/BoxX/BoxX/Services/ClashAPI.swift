import Foundation

actor ClashAPI {
    let baseURL: String
    private let session: URLSession
    private let secret: String

    init(baseURL: String = "http://127.0.0.1:9091", secret: String = "") {
        self.baseURL = baseURL
        self.secret = secret
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    func getProxies() async throws -> [ProxyGroup] {
        let data = try await get("/proxies")
        let response = try JSONDecoder().decode(ProxiesResponse.self, from: data)

        // Get order from GLOBAL group's `all` field (matches config file order)
        let globalOrder = response.proxies["GLOBAL"]?.all ?? []

        let groups = response.proxies.compactMap { (_, detail) -> ProxyGroup? in
            guard detail.type == "Selector" || detail.type == "URLTest" || detail.type == "Fallback" else { return nil }
            return ProxyGroup(name: detail.name, type: detail.type, now: detail.now, all: detail.all)
        }

        // Sort by GLOBAL order, unknown items at the end
        return groups.sorted { a, b in
            let ia = globalOrder.firstIndex(of: a.name) ?? Int.max
            let ib = globalOrder.firstIndex(of: b.name) ?? Int.max
            return ia < ib
        }
    }

    func getProxyDetail(name: String) async throws -> ProxyDetail {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let data = try await get("/proxies/\(encoded)")
        return try JSONDecoder().decode(ProxyDetail.self, from: data)
    }

    func selectProxy(group: String, name: String) async throws {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        let body = try JSONEncoder().encode(["name": name])
        _ = try await put("/proxies/\(encoded)", body: body)
    }

    func getDelay(name: String, url: String = "http://www.gstatic.com/generate_204", timeout: Int = 5000) async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        let path = "/proxies/\(encoded)/delay?url=\(encodedURL)&timeout=\(timeout)"
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "GET"
        // Allow enough time for sing-box to complete the delay test
        request.timeoutInterval = TimeInterval(timeout / 1000 + 3)
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let result = try JSONDecoder().decode([String: Int].self, from: data)
        return result["delay"] ?? 0
    }

    /// Test all proxies in a group at once via Clash group delay API.
    /// Returns a dictionary of node name → delay (ms). Nodes with 0 delay are timed out.
    func getGroupDelay(group: String, url: String = "http://cp.cloudflare.com/generate_204", timeout: Int = 5000) async throws -> [String: Int] {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        let path = "/group/\(encoded)/delay?url=\(encodedURL)&timeout=\(timeout)"
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(timeout / 1000 + 5)
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    func getRules() async throws -> [Rule] {
        let data = try await get("/rules")
        let decoded = try JSONDecoder().decode(RulesResponse.self, from: data)
        return decoded.rules.enumerated().map { Rule(id: $0, type: $1.type, payload: $1.payload, proxy: $1.proxy) }
    }

    func getConnections() async throws -> ConnectionSnapshot {
        let data = try await get("/connections")
        return try JSONDecoder().decode(ConnectionSnapshot.self, from: data)
    }

    func closeConnection(id: String) async throws { _ = try await delete("/connections/\(id)") }
    func closeAllConnections() async throws { _ = try await delete("/connections") }

    func getConfig() async throws -> ClashConfig {
        let data = try await get("/configs")
        return try JSONDecoder().decode(ClashConfig.self, from: data)
    }

    /// Hot-reload config via Clash API PUT /configs (no restart, no password)
    func reloadConfig(path: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["path": path])
        _ = try await put("/configs", body: body)
    }

    func setMode(_ mode: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["mode": mode])
        _ = try await patch("/configs", body: body)
    }

    /// Test which rule a domain matches by making a real connection through the proxy
    func testRule(domain: String, proxyPort: Int = 7890) async -> RuleTestResult? {
        let domainLower = domain.lowercased()

        // Fire a test request through the HTTP proxy (don't await result)
        let proxyConfig = URLSessionConfiguration.ephemeral
        proxyConfig.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: proxyPort,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort: proxyPort,
        ] as [String: Any]
        proxyConfig.timeoutIntervalForRequest = 5
        let proxySession = URLSession(configuration: proxyConfig)

        // Launch request in background, don't wait for it to complete
        Task.detached {
            _ = try? await proxySession.data(from: URL(string: "https://\(domain)")!)
            proxySession.invalidateAndCancel()
        }

        // Poll connections multiple times to find the match
        for attempt in 0..<6 {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 300 : 500))

            guard let snapshot = try? await getConnections(),
                  let connections = snapshot.connections else { continue }

            // Search broadly: exact match, contains, or www. prefix
            if let conn = connections.first(where: { conn in
                let host = conn.metadata.host.lowercased()
                return host == domainLower ||
                       host == "www.\(domainLower)" ||
                       host.hasSuffix(".\(domainLower)") ||
                       domainLower.hasSuffix(".\(host)")
            }) {
                return RuleTestResult(
                    domain: domain,
                    rule: conn.rule,
                    outbound: conn.outbound,
                    chain: conn.chain,
                    destinationIP: conn.metadata.destinationIP
                )
            }
        }
        return nil
    }

    func isReachable() async -> Bool {
        do { _ = try await get("/"); return true } catch { return false }
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "GET"
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func put(_ path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func patch(_ path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "PATCH"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func delete(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "DELETE"
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func addAuth(_ request: inout URLRequest) {
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
    }
}

struct ClashConfig: Codable {
    let mode: String?
    let mixedPort: Int?
    let port: Int?
    let socksPort: Int?
    let allowLan: Bool?
    let logLevel: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case mixedPort = "mixed-port"
        case port
        case socksPort = "socks-port"
        case allowLan = "allow-lan"
        case logLevel = "log-level"
    }
}

struct RuleTestResult {
    let domain: String
    let rule: String
    let outbound: String
    let chain: String
    let destinationIP: String
}

enum ClashAPIError: Error, LocalizedError {
    case httpError(Int)
    var errorDescription: String? {
        switch self { case .httpError(let code): return "HTTP \(code)" }
    }
}

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
        return response.proxies.compactMap { (_, detail) in
            guard detail.type == "Selector" || detail.type == "URLTest" || detail.type == "Fallback" else { return nil }
            return ProxyGroup(name: detail.name, type: detail.type, now: detail.now, all: detail.all)
        }.sorted { $0.name < $1.name }
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

    func getDelay(name: String, url: String = "http://www.gstatic.com/generate_204", timeout: Int = 8000) async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        let data = try await get("/proxies/\(encoded)/delay?url=\(encodedURL)&timeout=\(timeout)")
        let result = try JSONDecoder().decode([String: Int].self, from: data)
        return result["delay"] ?? 0
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

enum ClashAPIError: Error, LocalizedError {
    case httpError(Int)
    var errorDescription: String? {
        switch self { case .httpError(let code): return "HTTP \(code)" }
    }
}

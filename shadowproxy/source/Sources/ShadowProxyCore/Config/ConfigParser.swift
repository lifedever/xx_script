import Foundation

// MARK: - Config Types

public enum GroupType: String, Sendable {
    case select
    case urlTest = "url-test"
}

public struct GeneralConfig: Sendable {
    public let port: UInt16
    public let skipProxy: [String]
    public let dnsServer: String
    public let logLevel: String

    public init(port: UInt16 = 7890, skipProxy: [String] = [], dnsServer: String = "https://223.5.5.5/dns-query", logLevel: String = "info") {
        self.port = port
        self.skipProxy = skipProxy
        self.dnsServer = dnsServer
        self.logLevel = logLevel
    }
}

public struct ProxyGroup: Sendable {
    public let name: String
    public let type: GroupType
    public let members: [String]

    public init(name: String, type: GroupType, members: [String]) {
        self.name = name
        self.type = type
        self.members = members
    }
}

public enum Rule: Sendable, Equatable {
    case domainSuffix(String, String)
    case domain(String, String)
    case ipCIDR(String, String)
    case geoIP(String, String)
    case ruleSet(String, String)  // (url string, policy)
    case final(String)
}

public struct AppConfig: Sendable {
    public let general: GeneralConfig
    public let proxies: [String: ServerConfig]
    public let groups: [ProxyGroup]
    public let rules: [Rule]

    public init(general: GeneralConfig, proxies: [String: ServerConfig], groups: [ProxyGroup], rules: [Rule]) {
        self.general = general
        self.proxies = proxies
        self.groups = groups
        self.rules = rules
    }
}

// MARK: - Parser

public struct ConfigParser {

    public init() {}

    public func parse(_ content: String) throws -> AppConfig {
        var currentSection = ""
        var generalLines: [String] = []
        var proxyLines: [String] = []
        var groupLines: [String] = []
        var ruleLines: [String] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }

            switch currentSection {
            case "General":     generalLines.append(line)
            case "Proxy":       proxyLines.append(line)
            case "Proxy Group": groupLines.append(line)
            case "Rule":        ruleLines.append(line)
            default: break
            }
        }

        let general = parseGeneral(generalLines)
        let proxies = parseProxies(proxyLines)
        let groups = parseGroups(groupLines)
        let rules = parseRules(ruleLines)

        return AppConfig(general: general, proxies: proxies, groups: groups, rules: rules)
    }

    public func parse(fileAt path: String) throws -> AppConfig {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(content)
    }

    // MARK: - General

    private func parseGeneral(_ lines: [String]) -> GeneralConfig {
        var port: UInt16 = 7890
        var skipProxy: [String] = []
        var dnsServer = "https://223.5.5.5/dns-query"
        var logLevel = "info"

        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1]

            switch key {
            case "port":
                port = UInt16(value) ?? 7890
            case "skip-proxy":
                skipProxy = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "dns-server":
                dnsServer = value
            case "loglevel":
                logLevel = value
            default: break
            }
        }

        return GeneralConfig(port: port, skipProxy: skipProxy, dnsServer: dnsServer, logLevel: logLevel)
    }

    // MARK: - Proxies

    private func parseProxies(_ lines: [String]) -> [String: ServerConfig] {
        var result: [String: ServerConfig] = [:]

        for line in lines {
            let nameAndRest = line.split(separator: "=", maxSplits: 1)
            guard nameAndRest.count == 2 else { continue }

            let name = nameAndRest[0].trimmingCharacters(in: .whitespaces)
            let parts = nameAndRest[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }

            let proto = parts[0].lowercased()
            let server = parts[1]
            guard let port = UInt16(parts[2]) else { continue }

            // Parse key=value pairs from remaining parts
            var params: [String: String] = [:]
            for i in 3..<parts.count {
                let kv = parts[i].split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    params[String(kv[0]).lowercased()] = String(kv[1])
                }
            }

            let transport = TransportConfig(
                tls: params["tls"]?.lowercased() == "true",
                tlsSNI: params["sni"],
                tlsALPN: params["alpn"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                tlsAllowInsecure: params["skip-cert-verify"]?.lowercased() == "true",
                wsPath: params["ws-path"],
                wsHost: params["ws-host"]
            )

            switch proto {
            case "ss", "shadowsocks":
                let config = ShadowsocksConfig(
                    server: server,
                    port: port,
                    method: params["encrypt-method"] ?? "aes-128-gcm",
                    password: params["password"] ?? "",
                    obfsPlugin: params["obfs"] != nil ? "obfs-http" : nil,
                    obfsHost: params["obfs-host"],
                    transport: transport
                )
                result[name] = .shadowsocks(config)

            case "vmess":
                let config = VMessConfig(
                    server: server,
                    port: port,
                    uuid: params["username"] ?? params["uuid"] ?? "",
                    alterId: Int(params["alterid"] ?? "0") ?? 0,
                    security: params["security"] ?? "auto",
                    transport: transport
                )
                result[name] = .vmess(config)

            case "vless":
                let config = VLESSConfig(
                    server: server, port: port,
                    uuid: params["uuid"] ?? "",
                    transport: transport
                )
                result[name] = .vless(config)

            case "trojan":
                let config = TrojanConfig(
                    server: server, port: port,
                    password: params["password"] ?? "",
                    transport: transport
                )
                result[name] = .trojan(config)

            default: break
            }
        }

        return result
    }

    // MARK: - Groups

    private func parseGroups(_ lines: [String]) -> [ProxyGroup] {
        var groups: [ProxyGroup] = []

        for line in lines {
            let nameAndRest = line.split(separator: "=", maxSplits: 1)
            guard nameAndRest.count == 2 else { continue }

            let name = nameAndRest[0].trimmingCharacters(in: .whitespaces)
            let parts = nameAndRest[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty else { continue }

            let typeStr = parts[0].lowercased()
            let groupType: GroupType
            switch typeStr {
            case "select": groupType = .select
            case "url-test": groupType = .urlTest
            default: continue
            }

            let members = parts.dropFirst().map { String($0) }
            groups.append(ProxyGroup(name: name, type: groupType, members: members))
        }

        return groups
    }

    // MARK: - Rules

    private func parseRules(_ lines: [String]) -> [Rule] {
        var rules: [Rule] = []

        for line in lines {
            let parts = line.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }

            if parts.count == 2 && parts[0].uppercased() == "FINAL" {
                rules.append(.final(parts[1]))
                continue
            }

            guard parts.count >= 2 else { continue }

            let ruleType = parts[0].uppercased()
            let value = parts.count > 1 ? parts[1] : ""
            let policy = parts.count > 2 ? parts[2] : ""

            switch ruleType {
            case "DOMAIN-SUFFIX":
                rules.append(.domainSuffix(value, policy))
            case "DOMAIN":
                rules.append(.domain(value, policy))
            case "IP-CIDR":
                rules.append(.ipCIDR(value, policy))
            case "GEOIP":
                rules.append(.geoIP(value, policy))
            case "RULE-SET":
                rules.append(.ruleSet(value, policy))
            default: break
            }
        }

        return rules
    }
}

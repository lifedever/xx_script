import Foundation

public final class Router: Sendable {
    private let rules: [ResolvedRule]
    private let finalPolicy: String

    public init(rules: [Rule]) {
        var resolved: [ResolvedRule] = []
        var finalPolicy = "DIRECT"

        for rule in rules {
            switch rule {
            case .domainSuffix(let suffix, let policy):
                resolved.append(.domainSuffix(suffix.lowercased(), policy))
            case .domain(let domain, let policy):
                resolved.append(.domain(domain.lowercased(), policy))
            case .ipCIDR(let cidr, let policy):
                if let parsed = CIDRRange(cidr) {
                    resolved.append(.ipCIDR(parsed, policy))
                }
            case .geoIP(_, let policy):
                // Phase 1: GEOIP 简化实现，仅匹配私有 IP 段作为 CN
                // 完整实现需要 mmdb，留到后续
                resolved.append(.geoIPCN(policy))
            case .ruleSet(_, _):
                // RULE-SET 的规则在 RuleSetLoader 加载后展开插入
                break
            case .final(let policy):
                finalPolicy = policy
            }
        }

        self.rules = resolved
        self.finalPolicy = finalPolicy
    }

    /// 带已展开的 RULE-SET 规则初始化
    public convenience init(rules: [Rule], expandedRuleSets: [String: [Rule]]) {
        var allRules: [Rule] = []
        for rule in rules {
            if case .ruleSet(let url, let policy) = rule,
               let setRules = expandedRuleSets[url] {
                // 展开 RULE-SET 为具体规则，policy 覆盖为 RULE-SET 指定的 policy
                for setRule in setRules {
                    switch setRule {
                    case .domainSuffix(let v, _): allRules.append(.domainSuffix(v, policy))
                    case .domain(let v, _): allRules.append(.domain(v, policy))
                    case .ipCIDR(let v, _): allRules.append(.ipCIDR(v, policy))
                    default: break
                    }
                }
            } else {
                allRules.append(rule)
            }
        }
        self.init(rules: allRules)
    }

    public func match(host: String) -> String {
        let lowerHost = host.lowercased()

        for rule in rules {
            switch rule {
            case .domainSuffix(let suffix, let policy):
                if lowerHost == suffix || lowerHost.hasSuffix("." + suffix) {
                    return policy
                }
            case .domain(let domain, let policy):
                if lowerHost == domain {
                    return policy
                }
            case .ipCIDR(let cidr, let policy):
                if let ip = IPv4Address(host), cidr.contains(ip) {
                    return policy
                }
            case .geoIPCN(let policy):
                // 简化：检查是否为中国常见 IP 段（后续用 mmdb 替换）
                if let ip = IPv4Address(host), isPrivateOrCNIP(ip) {
                    return policy
                }
            }
        }

        return finalPolicy
    }

    private func isPrivateOrCNIP(_ ip: IPv4Address) -> Bool {
        // 私有 IP 段视为直连
        let val = ip.value
        if val >> 24 == 10 { return true }                        // 10.0.0.0/8
        if val >> 20 == 0xAC1 { return true }                     // 172.16.0.0/12
        if val >> 16 == 0xC0A8 { return true }                    // 192.168.0.0/16
        if val >> 22 == 0x644 >> 2 { return true }                // 100.64.0.0/10
        return false
    }
}

// MARK: - Internal Types

private enum ResolvedRule {
    case domainSuffix(String, String)
    case domain(String, String)
    case ipCIDR(CIDRRange, String)
    case geoIPCN(String)
}

// MARK: - IPv4 Helpers

struct IPv4Address {
    let value: UInt32

    init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 4,
              let a = UInt32(parts[0]), a <= 255,
              let b = UInt32(parts[1]), b <= 255,
              let c = UInt32(parts[2]), c <= 255,
              let d = UInt32(parts[3]), d <= 255 else {
            return nil
        }
        self.value = (a << 24) | (b << 16) | (c << 8) | d
    }
}

struct CIDRRange {
    let network: UInt32
    let mask: UInt32

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let ip = IPv4Address(String(parts[0])),
              let prefix = UInt32(parts[1]), prefix <= 32 else {
            return nil
        }
        self.mask = prefix == 0 ? 0 : ~((1 << (32 - prefix)) - 1)
        self.network = ip.value & self.mask
    }

    func contains(_ ip: IPv4Address) -> Bool {
        return (ip.value & mask) == network
    }
}

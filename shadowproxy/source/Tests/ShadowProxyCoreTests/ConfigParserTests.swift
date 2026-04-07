import Testing
@testable import ShadowProxyCore

@Test func parseGeneral() throws {
    let conf = """
    [General]
    skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8
    dns-server = https://223.5.5.5/dns-query
    loglevel = info
    """
    let config = try ConfigParser().parse(conf)
    #expect(config.general.skipProxy.count == 3)
    #expect(config.general.skipProxy[0] == "127.0.0.1")
    #expect(config.general.dnsServer == "https://223.5.5.5/dns-query")
    #expect(config.general.logLevel == "info")
}

@Test func parseShadowsocksProxy() throws {
    let conf = """
    [Proxy]
    🇭🇰香港-IEPL = ss, gd.bjnet2.com, 36602, encrypt-method=aes-128-gcm, password=test123, obfs=http, obfs-host=baidu.com
    """
    let config = try ConfigParser().parse(conf)
    #expect(config.proxies.count == 1)
    guard case .shadowsocks(let ss) = config.proxies["🇭🇰香港-IEPL"] else {
        Issue.record("Expected shadowsocks config")
        return
    }
    #expect(ss.server == "gd.bjnet2.com")
    #expect(ss.port == 36602)
    #expect(ss.method == "aes-128-gcm")
    #expect(ss.password == "test123")
    #expect(ss.obfsPlugin == "obfs-http")
    #expect(ss.obfsHost == "baidu.com")
}

@Test func parseVMessProxy() throws {
    let conf = """
    [Proxy]
    🇯🇵 日本 | V1 | 01 = vmess, g3.merivox.net, 11101, username=ea03770f-be81-3903-b81d-19a0d0e8844f, alterId=0
    """
    let config = try ConfigParser().parse(conf)
    #expect(config.proxies.count == 1)
    guard case .vmess(let vm) = config.proxies["🇯🇵 日本 | V1 | 01"] else {
        Issue.record("Expected vmess config")
        return
    }
    #expect(vm.server == "g3.merivox.net")
    #expect(vm.port == 11101)
    #expect(vm.uuid == "ea03770f-be81-3903-b81d-19a0d0e8844f")
    #expect(vm.alterId == 0)
}

@Test func parseProxyGroups() throws {
    let conf = """
    [Proxy Group]
    Proxy = select, 🇯🇵 日本, 🇭🇰 香港
    🤖OpenAI = select, Proxy, 🇯🇵 日本
    """
    let config = try ConfigParser().parse(conf)
    #expect(config.groups.count == 2)
    #expect(config.groups[0].name == "Proxy")
    #expect(config.groups[0].type == .select)
    #expect(config.groups[0].members == ["🇯🇵 日本", "🇭🇰 香港"])
    #expect(config.groups[1].name == "🤖OpenAI")
    #expect(config.groups[1].members == ["Proxy", "🇯🇵 日本"])
}

@Test func parseRules() throws {
    let conf = """
    [Rule]
    DOMAIN-SUFFIX,anthropic.com,🤖OpenAI
    DOMAIN,example.com,DIRECT
    IP-CIDR,10.6.0.0/16,DIRECT
    GEOIP,CN,DIRECT
    RULE-SET,https://example.com/rules.list,Proxy
    FINAL,🐟漏网之鱼
    """
    let config = try ConfigParser().parse(conf)
    #expect(config.rules.count == 6)
    #expect(config.rules[0] == .domainSuffix("anthropic.com", "🤖OpenAI"))
    #expect(config.rules[1] == .domain("example.com", "DIRECT"))
    #expect(config.rules[2] == .ipCIDR("10.6.0.0/16", "DIRECT"))
    #expect(config.rules[3] == .geoIP("CN", "DIRECT"))
    #expect(config.rules[4] == .ruleSet("https://example.com/rules.list", "Proxy"))
    #expect(config.rules[5] == .final("🐟漏网之鱼"))
}

@Test func parseFullConfig() throws {
    let conf = """
    # ShadowProxy config
    [General]
    skip-proxy = 127.0.0.1, 192.168.0.0/16
    dns-server = https://223.5.5.5/dns-query

    [Proxy]
    🇭🇰香港 = ss, gd.bjnet2.com, 36602, encrypt-method=aes-128-gcm, password=test123
    🇯🇵日本 = vmess, g3.merivox.net, 11101, username=ea03770f-be81-3903-b81d-19a0d0e8844f

    [Proxy Group]
    Proxy = select, 🇭🇰香港, 🇯🇵日本
    🤖OpenAI = select, Proxy, 🇯🇵日本

    [Rule]
    DOMAIN-SUFFIX,anthropic.com,🤖OpenAI
    GEOIP,CN,DIRECT
    FINAL,Proxy
    """
    let config = try ConfigParser().parse(conf)
    #expect(config.general.skipProxy.count == 2)
    #expect(config.proxies.count == 2)
    #expect(config.groups.count == 2)
    #expect(config.rules.count == 3)
}

@Test func parseVLESSProxy() throws {
    let conf = """
    [Proxy]
    JP-VLESS = vless, server.com, 443, uuid=ea03770f-be81-3903-b81d-19a0d0e8844f, tls=true, sni=server.com, ws-path=/ws
    """
    let config = try ConfigParser().parse(conf)
    guard case .vless(let v) = config.proxies["JP-VLESS"] else {
        Issue.record("Expected vless config"); return
    }
    #expect(v.server == "server.com")
    #expect(v.port == 443)
    #expect(v.uuid == "ea03770f-be81-3903-b81d-19a0d0e8844f")
    #expect(v.transport.tls == true)
    #expect(v.transport.tlsSNI == "server.com")
    #expect(v.transport.wsPath == "/ws")
}

@Test func parseTrojanProxy() throws {
    let conf = """
    [Proxy]
    JP-Trojan = trojan, trojan.server.com, 443, password=mypassword, sni=trojan.server.com
    """
    let config = try ConfigParser().parse(conf)
    guard case .trojan(let t) = config.proxies["JP-Trojan"] else {
        Issue.record("Expected trojan config"); return
    }
    #expect(t.server == "trojan.server.com")
    #expect(t.port == 443)
    #expect(t.password == "mypassword")
    #expect(t.transport.tls == true)
    #expect(t.transport.tlsSNI == "trojan.server.com")
}

@Test func parseVMessWithTransport() throws {
    let conf = """
    [Proxy]
    JP-VMess = vmess, g3.merivox.net, 443, username=ea03770f-be81-3903-b81d-19a0d0e8844f, alterId=0, tls=true, sni=g3.merivox.net, ws-path=/vmess
    """
    let config = try ConfigParser().parse(conf)
    guard case .vmess(let v) = config.proxies["JP-VMess"] else {
        Issue.record("Expected vmess config"); return
    }
    #expect(v.transport.tls == true)
    #expect(v.transport.wsPath == "/vmess")
}

@Test func existingConfigStillWorks() throws {
    let conf = """
    [Proxy]
    HK = ss, gd.bjnet2.com, 36602, encrypt-method=aes-128-gcm, password=test123, obfs=http, obfs-host=baidu.com
    JP = vmess, g3.merivox.net, 11101, username=ea03770f-be81-3903-b81d-19a0d0e8844f, alterId=0
    """
    let config = try ConfigParser().parse(conf)
    guard case .shadowsocks(let ss) = config.proxies["HK"] else {
        Issue.record("Expected ss"); return
    }
    #expect(ss.transport.tls == false)
    #expect(ss.transport.wsPath == nil)
    guard case .vmess(let vm) = config.proxies["JP"] else {
        Issue.record("Expected vmess"); return
    }
    #expect(vm.transport.tls == false)
}

@Test func ignoresCommentsAndEmptyLines() throws {
    let conf = """
    [General]
    # this is a comment
    dns-server = https://223.5.5.5/dns-query

    [Rule]
    # AI rules
    DOMAIN-SUFFIX,openai.com,Proxy
    """
    let config = try ConfigParser().parse(conf)
    #expect(config.general.dnsServer == "https://223.5.5.5/dns-query")
    #expect(config.rules.count == 1)
}

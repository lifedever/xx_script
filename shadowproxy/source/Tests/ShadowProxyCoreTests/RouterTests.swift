import Testing
@testable import ShadowProxyCore

@Test func matchDomainSuffix() {
    let router = Router(rules: [
        .domainSuffix("anthropic.com", "🤖OpenAI"),
        .domainSuffix("openai.com", "🤖OpenAI"),
        .final("Proxy"),
    ])
    #expect(router.match(host: "api.anthropic.com") == "🤖OpenAI")
    #expect(router.match(host: "anthropic.com") == "🤖OpenAI")
    #expect(router.match(host: "chat.openai.com") == "🤖OpenAI")
    #expect(router.match(host: "google.com") == "Proxy")
}

@Test func matchExactDomain() {
    let router = Router(rules: [
        .domain("example.com", "DIRECT"),
        .final("Proxy"),
    ])
    #expect(router.match(host: "example.com") == "DIRECT")
    #expect(router.match(host: "sub.example.com") == "Proxy")
}

@Test func matchIPCIDR() {
    let router = Router(rules: [
        .ipCIDR("10.6.0.0/16", "DIRECT"),
        .ipCIDR("192.168.0.0/16", "DIRECT"),
        .final("Proxy"),
    ])
    #expect(router.match(host: "10.6.1.1") == "DIRECT")
    #expect(router.match(host: "10.7.0.1") == "Proxy")
    #expect(router.match(host: "192.168.1.1") == "DIRECT")
}

@Test func matchFinal() {
    let router = Router(rules: [
        .domainSuffix("local", "DIRECT"),
        .final("🐟漏网之鱼"),
    ])
    #expect(router.match(host: "unknown.example.com") == "🐟漏网之鱼")
}

@Test func rulesMatchInOrder() {
    let router = Router(rules: [
        .domainSuffix("example.com", "First"),
        .domainSuffix("example.com", "Second"),
        .final("Last"),
    ])
    // First match wins
    #expect(router.match(host: "example.com") == "First")
}

@Test func expandedRuleSets() {
    let ruleSetRules: [Rule] = [
        .domainSuffix("anthropic.com", ""),
        .domainSuffix("claude.ai", ""),
    ]
    let router = Router(
        rules: [
            .ruleSet("https://example.com/ai.list", "🤖OpenAI"),
            .final("Proxy"),
        ],
        expandedRuleSets: ["https://example.com/ai.list": ruleSetRules]
    )
    #expect(router.match(host: "api.anthropic.com") == "🤖OpenAI")
    #expect(router.match(host: "claude.ai") == "🤖OpenAI")
    #expect(router.match(host: "google.com") == "Proxy")
}

@Test func ruleSetLoaderParsesList() {
    let loader = RuleSetLoader()
    let content = """
    # AI rules
    DOMAIN-SUFFIX,anthropic.com
    DOMAIN-SUFFIX,openai.com
    DOMAIN,chat.openai.com
    IP-CIDR,10.0.0.0/8
    """
    let rules = loader.parseList(content)
    #expect(rules.count == 4)
    #expect(rules[0] == .domainSuffix("anthropic.com", ""))
    #expect(rules[1] == .domainSuffix("openai.com", ""))
    #expect(rules[2] == .domain("chat.openai.com", ""))
    #expect(rules[3] == .ipCIDR("10.0.0.0/8", ""))
}

@Test func caseInsensitiveMatch() {
    let router = Router(rules: [
        .domainSuffix("Anthropic.COM", "AI"),
        .final("Other"),
    ])
    #expect(router.match(host: "API.ANTHROPIC.COM") == "AI")
    #expect(router.match(host: "api.anthropic.com") == "AI")
}

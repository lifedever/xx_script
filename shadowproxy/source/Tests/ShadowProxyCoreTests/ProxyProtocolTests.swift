import Testing
@testable import ShadowProxyCore

@Test func proxyTargetInit() {
    let target = ProxyTarget(host: "example.com", port: 443)
    #expect(target.host == "example.com")
    #expect(target.port == 443)
}

@Test func shadowsocksConfigInit() {
    let config = ShadowsocksConfig(
        server: "gd.bjnet2.com",
        port: 36602,
        method: "aes-128-gcm",
        password: "test-password",
        obfsPlugin: "obfs-http",
        obfsHost: "baidu.com"
    )
    #expect(config.server == "gd.bjnet2.com")
    #expect(config.method == "aes-128-gcm")
    #expect(config.obfsPlugin == "obfs-http")
}

@Test func vmessConfigInit() {
    let config = VMessConfig(
        server: "g3.merivox.net",
        port: 11101,
        uuid: "ea03770f-be81-3903-b81d-19a0d0e8844f"
    )
    #expect(config.server == "g3.merivox.net")
    #expect(config.alterId == 0)
    #expect(config.security == "auto")
}

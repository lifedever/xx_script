import Testing
import Foundation
@testable import ShadowProxyCore

@Test func parseSsURI() throws {
    let method = "aes-128-gcm"
    let password = "testpass"
    let encoded = Data("\(method):\(password)".utf8).base64EncodedString()
    let uri = "ss://\(encoded)@1.2.3.4:8388#TestNode"

    let config = try SubscriptionParser.parseURI(uri)
    guard case .shadowsocks(let ss) = config.serverConfig else {
        Issue.record("Expected shadowsocks"); return
    }
    #expect(ss.server == "1.2.3.4")
    #expect(ss.port == 8388)
    #expect(ss.method == "aes-128-gcm")
    #expect(ss.password == "testpass")
    #expect(config.name == "TestNode")
}

@Test func parseVMessURI() throws {
    let json: [String: Any] = [
        "v": "2", "ps": "JP-Node", "add": "server.com", "port": "443",
        "id": "ea03770f-be81-3903-b81d-19a0d0e8844f", "aid": "0",
        "net": "ws", "tls": "tls", "sni": "server.com", "path": "/ws"
    ]
    let jsonData = try JSONSerialization.data(withJSONObject: json)
    let encoded = jsonData.base64EncodedString()
    let uri = "vmess://\(encoded)"

    let config = try SubscriptionParser.parseURI(uri)
    guard case .vmess(let vm) = config.serverConfig else {
        Issue.record("Expected vmess"); return
    }
    #expect(vm.server == "server.com")
    #expect(vm.port == 443)
    #expect(vm.uuid == "ea03770f-be81-3903-b81d-19a0d0e8844f")
    #expect(vm.transport.tls == true)
    #expect(vm.transport.wsPath == "/ws")
    #expect(config.name == "JP-Node")
}

@Test func parseTrojanURI() throws {
    let uri = "trojan://mypassword@server.com:443?sni=server.com#JP-Trojan"
    let config = try SubscriptionParser.parseURI(uri)
    guard case .trojan(let t) = config.serverConfig else {
        Issue.record("Expected trojan"); return
    }
    #expect(t.server == "server.com")
    #expect(t.port == 443)
    #expect(t.password == "mypassword")
    #expect(t.transport.tls == true)
    #expect(config.name == "JP-Trojan")
}

@Test func parseVLESSURI() throws {
    let uri = "vless://ea03770f-be81-3903-b81d-19a0d0e8844f@server.com:443?security=tls&sni=server.com&type=ws&path=/ws#JP-VLESS"
    let config = try SubscriptionParser.parseURI(uri)
    guard case .vless(let v) = config.serverConfig else {
        Issue.record("Expected vless"); return
    }
    #expect(v.server == "server.com")
    #expect(v.port == 443)
    #expect(v.uuid == "ea03770f-be81-3903-b81d-19a0d0e8844f")
    #expect(v.transport.tls == true)
    #expect(v.transport.wsPath == "/ws")
    #expect(config.name == "JP-VLESS")
}

@Test func parseBase64Subscription() throws {
    let uris = [
        "ss://\(Data("aes-128-gcm:pass1".utf8).base64EncodedString())@1.1.1.1:8388#Node1",
        "ss://\(Data("aes-128-gcm:pass2".utf8).base64EncodedString())@2.2.2.2:8388#Node2"
    ]
    let content = Data(uris.joined(separator: "\n").utf8).base64EncodedString()
    let nodes = try SubscriptionParser.parseSubscription(content)
    #expect(nodes.count == 2)
    #expect(nodes[0].name == "Node1")
    #expect(nodes[1].name == "Node2")
}

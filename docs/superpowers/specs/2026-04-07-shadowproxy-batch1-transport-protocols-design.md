# ShadowProxy 批次 1：传输层 + 协议补全 设计规格

> 日期：2026-04-07
> 状态：设计确认
> 前置：Phase 1 完成（CLI + 系统代理 + VMess/SS/DIRECT）

## 背景

Phase 1 的代理引擎已跑通，但所有连接走裸 TCP，缺少 TLS/WebSocket 传输层、现代协议（VLESS/Trojan）、流量混淆（VMess padding）、连接复用和 DNS 防泄漏。这些是生产级代理工具的必备能力，对标 Surge/sing-box/Shadowrocket。

## 目标

- 所有协议支持 TLS + WebSocket 传输，TLS 指纹与 Safari 一致（Network.framework 原生）
- 新增 VLESS、Trojan 协议
- VMess 支持 0x05/0x1D padding，默认最安全模式
- ~~连接池~~ 移除（代理协议不支持连接复用，一连接一请求是正确模式）
- DIRECT 连接走 DoH 防 DNS 泄漏
- 现有配置文件向后兼容

## 技术方案：Network.framework 原生传输

不自建 TLS/WebSocket 实现，直接用 Network.framework 的 `NWProtocolTLS` 和 `NWProtocolWebSocket`。

**核心优势**：TLS 指纹就是 macOS 系统 TLS（和 Safari 同一个栈），不需要 uTLS 伪装。这比 Go 的 uTLS 更强 — 它不是"模仿"浏览器，它就是系统原生 TLS。

---

## 1. 传输层改造

### 1.1 TransportConfig

```swift
public struct TransportConfig: Sendable {
    public var tls: Bool = false
    public var tlsSNI: String?              // 默认用 server 地址
    public var tlsALPN: [String]?           // 如 ["h2", "http/1.1"]
    public var tlsAllowInsecure: Bool = false
    public var wsPath: String?              // 有值则启用 WebSocket
    public var wsHost: String?              // WebSocket Host header
}
```

### 1.2 连接工厂

在 `Outbound` 中抽取 `createConnection()` 方法：

```
createConnection(server, port, transport) → NWConnection
  ├── tls=false, wsPath=nil  → 裸 TCP（NWParameters.tcp）
  ├── tls=true,  wsPath=nil  → NWParameters(tls: tlsOptions, tcp: tcpOptions)
  ├── tls=false, wsPath!=nil → TCP + NWProtocolWebSocket
  └── tls=true,  wsPath!=nil → TLS + NWProtocolWebSocket
```

TLS 配置：
- SNI：通过 `sec_protocol_options_set_tls_server_name()` 设置
- ALPN：通过 `sec_protocol_options_add_tls_application_protocol()` 设置
- 证书验证：`tlsAllowInsecure=true` 时通过 `sec_protocol_options_set_verify_block()` 跳过

WebSocket 配置：
- `NWProtocolWebSocket.Options()` 设置 path
- Host header 通过 WebSocket additional headers 设置

### 1.3 改动范围

- `Outbound.swift`：抽出 `createConnection()`，替换现有三处 `NWConnection(host:port:using:.tcp)`
- 新增 `TransportConfig` 到 `ProxyProtocol.swift`
- 各协议 Config 持有 `TransportConfig`

---

## 2. VLESS 协议

### 2.1 协议描述

VLESS 不做加密，完全依赖 TLS 传输层。

请求头：
```
[version(1): 0x00]
[uuid(16): 二进制]
[addons_len(1): 0x00（无扩展）]
[command(1): 0x01=TCP]
[port(2): 大端序]
[addr_type(1): 0x01=IPv4(4B), 0x02=Domain(1B长度+NB), 0x03=IPv6(16B)]
[addr(N)]
```

响应头：
```
[version(1): 0x00]
[addons_len(1): 0x00]
```

读完响应头后原始数据透传。

### 2.2 实现

- 新增 `Sources/ShadowProxyCore/Protocol/VLESS.swift`
- `VLESSConfig`：server, port, uuid, transport
- `ServerConfig` 新增 `.vless(VLESSConfig)`
- `Outbound.relay()` 增加 `case .vless`
- 握手后走 `Relay.bridge()` 双向透传

### 2.3 配置格式

```ini
节点名 = vless, server, port, uuid=xxx, tls=true, sni=xxx, ws-path=/ws
```

---

## 3. Trojan 协议

### 3.1 协议描述

伪装为正常 HTTPS 流量，强制 TLS。

请求头：
```
[password_sha224_hex(56): ASCII]
[CRLF(2)]
[command(1): 0x01=TCP, 0x03=UDP]
[addr_type(1): SOCKS5 格式]
[addr(N)]
[port(2): 大端序]
[CRLF(2)]
```

无响应头，发完请求直接透传。

### 3.2 抗检测特性

- 外部只能看到标准 TLS 流量
- 无协议特征头
- 服务端对非法请求 fallback 到真实网站，主动探测无法识别

### 3.3 实现

- 新增 `Sources/ShadowProxyCore/Protocol/Trojan.swift`
- `TrojanConfig`：server, port, password, transport（transport.tls 强制 true）
- `ServerConfig` 新增 `.trojan(TrojanConfig)`
- SHA224 用 CommonCrypto 的 `CC_SHA224`（CryptoKit 不支持 SHA-224，它有独立初始向量，不是 SHA-256 截断）
- 握手后走 `Relay.bridge()` 透传

### 3.4 配置格式

```ini
节点名 = trojan, server, port, password=xxx, sni=xxx
```

---

## 4. VMess Padding 增强

### 4.1 现状

当前用 `option=0x01`（ChunkStream）：`[明文2字节长度][GCM加密payload]`，包大小直接暴露真实数据大小。

### 4.2 option=0x05（ChunkMasking）

长度字段加密：
```
[GCM加密的2字节长度(18B)] [GCM加密的payload(N+16B)]
```
- 长度用 SHAKE-128 流密码生成 mask 做 XOR，再 GCM 加密
- SHAKE-128 用 `reqIV` 作为 seed

### 4.3 option=0x1D（ChunkMasking + GlobalPadding）

每个 chunk 追加随机填充：
```
[GCM加密的2字节长度(18B)] [GCM加密的(payload+padding)(N+P+16B)]
```
- padding 长度由 SHAKE-128 生成（0~63 字节）
- 接收方通过长度字段知道真实长度，丢弃 padding

### 4.4 实现

- `VMessDataCipher` 新增 SHAKE-128 状态机
- 新增 `Sources/ShadowProxyCore/Crypto/SHAKE128.swift`：Keccak sponge XOF 模式，~100 行
- `VMessHeader.buildRequest()` 的 option 字段根据配置选择
- 默认使用 0x1D（最安全）
- 服务端自动适配客户端选择的 option，无需服务端配置

### 4.5 配置

不暴露给用户，内部默认 0x1D。`VMessConfig` 新增：
```swift
public var option: VMessOption = .chunkMaskingPadding  // 0x1D
```

---

## 5. 连接池 — 移除

设计自审时发现原方案有根本性错误：VLESS/Trojan/VMess/SS 的代理连接都是一次性的 — 每个连接对应一个目标地址，relay 结束后连接废弃。服务端不支持在同一个 TCP 连接上发起新的协议握手，因此 acquire/release 模型不适用。

Phase 1 的一连接一请求模式对这些协议是正确的做法。真正的连接复用需要多路复用协议（smux/yamux/XUDP），这是独立的复杂特性，留到后续批次。

本批次不新增 ConnectionPool.swift。

---

## 6. DNS 防泄漏

### 6.1 现状分析

- **代理连接**：域名写入协议头发给远端解析 — 已正确，无泄漏
- **DIRECT 连接**：`NWConnection(host:)` 传域名，Network.framework 用系统 DNS 解析 — 泄漏点

### 6.2 方案

新增 `DoHResolver`，DIRECT 连接改为先 DoH 解析再用 IP 建连：

```swift
final class DoHResolver {
    let server: String  // "https://223.5.5.5/dns-query"

    func resolve(_ domain: String) async throws -> String  // 返回 IP
}
```

- 通过 HTTPS GET 发送 DNS 查询（RFC 8484 DNS-over-HTTPS）
- 内置缓存，TTL 过期后重新查询
- 仅用于 DIRECT 连接，代理连接不经过此模块

### 6.3 实现

- 新增 `Sources/ShadowProxyCore/Engine/DoHResolver.swift`，~80 行
- `Outbound.relayDirect()` 改为先 DoH 解析，再用 IP 创建 NWConnection

### 6.4 SOCKS5 IPv4 模式

部分应用以 IPv4 地址（atyp=0x01）发送 SOCKS5 请求，此时本地 DNS 查询已发生，ShadowProxy 无法阻止。这是系统代理模式的固有局限，Phase 3 的 TUN 模式可彻底解决（拦截所有 DNS 查询）。当前不做反查，按 IP 走规则匹配。

---

## 7. 配置格式扩展

### 7.1 新增协议关键字

```ini
# VLESS
节点名 = vless, server, port, uuid=xxx, tls=true, sni=xxx, ws-path=/ws, ws-host=xxx

# Trojan
节点名 = trojan, server, port, password=xxx, sni=xxx

# 现有协议增加传输参数
节点名 = vmess, server, port, username=xxx, alterId=0, tls=true, sni=xxx, ws-path=/ws
节点名 = ss, server, port, encrypt-method=aes-128-gcm, password=xxx, tls=true, sni=xxx
```

### 7.2 传输参数一览

| 参数 | 适用协议 | 说明 |
|------|---------|------|
| `tls` | all | 是否启用 TLS（Trojan 强制 true） |
| `sni` | all | TLS SNI，默认用 server 地址 |
| `alpn` | all | TLS ALPN，逗号分隔 |
| `skip-cert-verify` | all | 跳过证书验证（默认 false） |
| `ws-path` | all | WebSocket 路径，有值则启用 WS |
| `ws-host` | all | WebSocket Host header |

### 7.3 ConfigParser 改动

- `parseProxies()` 新增 `case "vless"` 和 `case "trojan"` 分支
- 所有协议统一提取 `TransportConfig`
- `ServerConfig` enum 扩展为 5 个 case：direct, shadowsocks, vmess, vless, trojan

### 7.4 向后兼容

现有配置文件无需修改。新参数全部可选，默认值与 Phase 1 行为一致（裸 TCP、无 TLS、VMess option=0x01）。

---

## 文件变更清单

### 新增文件

| 文件 | 说明 | 预估行数 |
|------|------|---------|
| `Protocol/VLESS.swift` | VLESS 协议实现 | ~80 |
| `Protocol/Trojan.swift` | Trojan 协议实现 | ~60 |
| `Crypto/SHAKE128.swift` | SHAKE-128 XOF（Keccak sponge） | ~100 |
| `Engine/DoHResolver.swift` | DNS-over-HTTPS 解析器 | ~80 |

### 修改文件

| 文件 | 改动 |
|------|------|
| `Protocol/ProxyProtocol.swift` | 新增 TransportConfig, VLESSConfig, TrojanConfig; ServerConfig 增加 .vless/.trojan |
| `Protocol/VMess.swift` | VMessDataCipher 支持 0x05/0x1D; SHAKE-128 mask + padding 逻辑 |
| `Engine/Outbound.swift` | 抽出 createConnection(); 新增 relayVLESS/relayTrojan |
| `Config/ConfigParser.swift` | parseProxies 新增 vless/trojan; 提取 TransportConfig 解析 |

### 不变的文件

| 文件 | 理由 |
|------|------|
| `Engine/Inbound.swift` | 传输层改造在 Outbound 侧，Inbound 不变 |
| `Engine/Relay.swift` | bridge() 操作 NWConnection 接口不变 |
| `Router/Router.swift` | 路由逻辑不变 |
| `Router/RuleSetLoader.swift` | 规则集加载不变 |
| `System/SystemProxy.swift` | 系统代理设置不变 |
| `System/SleepWatcher.swift` | 睡眠恢复不变 |
| `System/Logger.swift` | 日志不变 |

---

## 测试策略

- VLESS/Trojan 单元测试：验证协议头构建正确性（和 v2ray 参考实现对比）
- SHAKE-128 单元测试：用 NIST 官方测试向量验证
- VMess 0x05/0x1D 单元测试：加密→解密 round-trip
- 连接池单元测试：acquire/release/evict/timeout
- DoH 集成测试：实际解析域名验证
- 端到端：配置 VLESS+WS+TLS 节点，验证完整代理链路

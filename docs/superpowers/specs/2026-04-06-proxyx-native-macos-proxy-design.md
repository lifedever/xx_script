# ShadowProxy：原生 macOS 代理工具设计规格

> 日期：2026-04-06
> 状态：Phase 1 设计确认

## 背景与动机

BoxX（基于 sing-box）存在两个无法接受的问题：
1. **TUN 模式延迟高** —— 比 Shadowrocket 慢 0.5-1 秒，Claude Code SSE 长连接体验差
2. **出站连接频繁断开** —— sing-box 进程每隔几分钟 outbound probe failed，触发反复重启

Shadowrocket 延迟和稳定性都满意，但后台连接偶尔失效。

**决策**：用纯 Swift 从零实现原生 macOS 代理工具，对标 Shadowrocket/Surge 的技术架构，追求极致低延迟和稳定性。

## 核心目标

- **延迟**：系统代理模式首包延迟 < 50ms，NE TUN 模式 < 100ms
- **稳定性**：长连接（SSE/WebSocket）零中断，睡眠唤醒自动恢复
- **可扩展**：协议层 Protocol 接口设计，新增协议不动其他代码

## 技术选型

| 维度 | 选择 | 理由 |
|------|------|------|
| 语言 | Swift 6.0 | 原生、无 GC、async/await 并发 |
| 网络 I/O | Network.framework（NWConnection/NWListener） | Apple 内核优化、零拷贝、硬件加速 |
| 加密 | CryptoKit + CommonCrypto | 系统库、AES-NI 硬件加速 |
| TUN 模式 | NEPacketTunnelProvider（Phase 2） | 系统托管进程生命周期 |
| 包管理 | SPM | 标准 Swift 包管理 |

## 整体架构

```
ShadowProxy.app（未来）/ ShadowProxyCLI（Phase 1）
├── 主进程
│   ├── ConfigParser          ← 配置解析（兼容 Shadowrocket .conf 格式）
│   ├── SystemProxyManager    ← 系统代理设置（SystemConfiguration 框架）
│   ├── Router                ← 规则匹配引擎
│   └── CLI Interface         ← Phase 1 命令行入口
│
├── Network Extension（Phase 2，系统扩展）
│   └── PacketTunnelProvider  ← TUN 全局模式
│
└── ProxyEngine（核心引擎，CLI 和 App 共享）
    ├── Inbound               ← HTTP/SOCKS5 本地监听
    ├── Outbound              ← 协议转发 + 连接池
    └── Protocol/             ← 可插拔协议实现
        ├── Shadowsocks
        ├── VMess
        └── Direct
```

### 和 Shadowrocket 的技术对齐

- Network.framework 原生网络栈（非用户态 Go net）
- 无 GC（ARC 引用计数，无 stop-the-world 暂停）
- 无独立进程链（不再有 App → Helper → sing-box）
- NE 模式由 macOS 系统托管进程生命周期

## 协议层设计

### 接口

```swift
protocol ProxyProtocol {
    var name: String { get }
    func connect(
        to target: ProxyTarget,
        via server: ServerConfig,
        using connection: NWConnection
    ) async throws -> ProxySession
}

protocol ProxySession {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}
```

### Phase 1 实现

- **Shadowsocks**：aes-128-gcm 加密 + obfs-http 插件
- **VMess**：AES-128-CFB / ChaCha20-Poly1305
- **Direct**：直连（不经过代理）

### 加密

全部使用 Apple 系统库：
- `CryptoKit`：ChaCha20-Poly1305、AES-GCM
- `CommonCrypto`：AES-CFB（CryptoKit 不支持 CFB 模式）

## Inbound（流量接入）

### 模式 1：系统代理（Phase 1）

- `NWListener` 监听 `127.0.0.1:7890`
- 支持 HTTP CONNECT 和 SOCKS5
- 通过 `SystemConfiguration` 框架设置系统 HTTP/SOCKS 代理
- 延迟最低，覆盖所有走系统代理的 app

### 模式 2：NE TUN（Phase 2）

- `NEPacketTunnelProvider` 系统扩展
- 解析 IP 包，提取 TCP/UDP 连接，通过 SNI 获取域名
- 全局覆盖，包括不走系统代理的 app
- macOS 系统保活

## Router（规则引擎）

### 规则类型

- `DOMAIN-SUFFIX` —— 匹配域名后缀
- `DOMAIN` —— 精确匹配域名
- `IP-CIDR` —— 匹配 IP 段
- `GEOIP` —— GeoIP 数据库匹配
- `PROCESS-NAME` —— 匹配进程名（TUN 模式）
- `RULE-SET` —— 远程规则集（兼容 Shadowrocket 格式，支持 HTTP 下载 + 本地缓存）
- `FINAL` —— 兜底规则

### 策略组

- `select` —— 手动选择
- `url-test` —— 自动选延迟最低节点，**已有连接不中断**

### DNS 策略

- 直连域名 → 本地 DoH 解析（223.5.5.5）
- 代理域名 → **不做本地 DNS 解析**，域名直接发给代理节点远端解析（避免 DNS 污染）
- 不使用 FakeIP（与 Shadowrocket 一致）

## 连接管理（稳定性核心）

### 连接池

- 同一代理节点的连接复用，避免重复 TCP + 代理握手
- 空闲连接保留 60 秒
- 默认 8 个并发连接/节点

### 长连接保护

- 代理连接建立后**不设 idle timeout**
- TCP keepalive 由 Network.framework 系统默认管理
- url-test 切换节点时，已有连接不中断，新连接走新节点

### 睡眠恢复

- 监听 `NSWorkspace.willSleepNotification` / `didWakeNotification`
- 唤醒后检测连接可用性，不可用则静默重建
- 不做全局重启

### 错误处理

- 单个连接失败 → 重试该连接，不影响其他
- 节点不可用 → 标记 down，不中断其他连接
- 绝不做"全部重启"

## 配置格式

兼容 Shadowrocket `.conf` 格式：

```ini
[General]
loglevel = info
skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8
dns-server = https://223.5.5.5/dns-query

[Proxy]
🇯🇵 日本 | V1 | 01 = vmess, server, port, uuid=xxx, ...
🇭🇰香港-IEPL = ss, server, port, encrypt-method=aes-128-gcm, password=xxx, obfs=http, ...

[Proxy Group]
Proxy = select, 🇯🇵 日本 | V1 | 01, 🇭🇰香港-IEPL
🤖OpenAI = select, Proxy, 🇯🇵 日本 | V1 | 01

[Rule]
DOMAIN-SUFFIX,anthropic.com,🤖OpenAI
DOMAIN-SUFFIX,openai.com,🤖OpenAI
GEOIP,CN,DIRECT
FINAL,Proxy
```

## CLI 命令（Phase 1）

```bash
sp start          # 启动（系统代理模式）
sp start --tun    # 启动（TUN 模式，Phase 2）
sp stop           # 停止
sp status         # 状态（模式、节点、连接数、延迟）
sp select <group> <node>  # 切换节点
sp test           # 测速
sp reload         # 重载配置
```

## 项目结构

```
ShadowProxy/
├── Package.swift
├── Sources/
│   ├── ShadowProxyCore/
│   │   ├── Engine/
│   │   │   ├── ProxyEngine.swift
│   │   │   ├── Inbound.swift
│   │   │   └── ConnectionPool.swift
│   │   ├── Protocol/
│   │   │   ├── ProxyProtocol.swift
│   │   │   ├── Shadowsocks.swift
│   │   │   └── VMess.swift
│   │   ├── Router/
│   │   │   ├── Router.swift
│   │   │   └── RuleParser.swift
│   │   ├── Config/
│   │   │   └── ConfigParser.swift
│   │   └── System/
│   │       ├── SystemProxy.swift
│   │       └── SleepWatcher.swift
│   └── ShadowProxyCLI/
│       └── main.swift
└── Tests/
    └── ShadowProxyCoreTests/
```

## Phase 划分

### Phase 1（本次实现）
- CLI 可用
- 系统代理模式（HTTP/SOCKS5）
- Shadowsocks + VMess 协议
- 规则引擎（内联规则 + RULE-SET 远程规则集）
- 连接池 + 长连接保护
- 睡眠恢复
- 交付标准：`sp start` 后 Claude Code 聊天无延迟、不断连

### Phase 2（后续）
- Network Extension TUN 全局模式
- macOS App + 菜单栏 UI
- 订阅自动解析
- 节点测速 UI

### Phase 3（远期）
- 更多协议（VLESS、Trojan、Hysteria）
- 流量统计
- 日志查看器

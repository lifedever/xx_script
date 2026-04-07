# ShadowProxy 后续开发计划

## Phase 1 完成总结（2026-04-07）

### 已完成
- **VMess AEAD 协议**：纯 Swift 实现，递归 HMAC KDF、AuthID、connectionNonce、AAD、GCM 数据加密，已调通 SoCloud VMess 节点
- **SS AEAD 协议**：加密/解密/relay 代码完成，obfs-http 被八戒服务商反代拦截（非代码问题）
- **Inbound**：NWListener HTTP CONNECT + SOCKS5 代理监听
- **系统 HTTP/HTTPS 代理**：networksetup，睡眠唤醒恢复，App 退出清理
- **规则路由**：DOMAIN-SUFFIX / DOMAIN / IP-CIDR / GEOIP / RULE-SET / FINAL
- **配置解析**：Shadowrocket .conf 格式，策略组，远程 RULE-SET 缓存
- **macOS SwiftUI App**：策略组切换、日志面板、Start/Stop
- **日志系统**：SPLogger 文件+控制台+UI，每次启动清空
- **41 个单元测试全部通过**

### 已知问题
- SS obfs-http 被八戒服务商反代返回 400（需排查或换服务商）
- 规则集异步加载，启动初期首批请求可能未匹配 DIRECT
- VMess 仅支持 option=0x01（ChunkStream），未实现 SHAKE-128 masking（0x05）和 GlobalPadding（0x1D）
- 直连模式未充分测试

---

## Phase 2：分流增强

### 目标
让不同服务走不同策略组（OpenAI → 日本，Netflix → 香港，国内 → DIRECT）

### 当前状态
- config.conf 已定义策略组（🤖OpenAI、▶️YouTube 等）和 RULE-SET 规则
- Router 匹配后返回策略名（如 "🤖OpenAI"）
- Outbound 解析策略名到具体节点

### 待实现
1. **Router 完善**：确保 RULE-SET 展开后的规则正确匹配到策略组
2. **规则集预加载**：启动时阻塞等待规则集加载完毕，再开始接受连接
3. **URL-Test 自动选优**：
   - 定时对策略组内节点做 TCP 握手延迟测试
   - 自动选择延迟最低的节点
   - 不中断已有连接
4. **PROCESS-NAME 规则**：按进程名分流（macOS 可通过 `proc_pidpath` 获取）
5. **UI 增强**：显示当前每个策略组选中的节点、延迟数据

### 工作量预估
- Router 完善 + 规则集预加载：1-2 小时
- URL-Test：3-4 小时
- PROCESS-NAME：2 小时
- UI：2-3 小时

---

## Phase 3：TUN 模式（NetworkExtension）

### 为什么需要 TUN
当前系统 HTTP 代理模式只能捕获 HTTP/HTTPS 流量，且仅对遵循系统代理设置的 App 有效。TUN 模式通过虚拟网卡捕获**所有 TCP/UDP 流量**，包括：
- 非浏览器 App（Terminal、游戏、IM）
- DNS 查询
- 非 HTTP 协议（SSH、SMTP 等）

### Shadowrocket macOS 的实现方式
Shadowrocket 使用 `NEPacketTunnelProvider`（NetworkExtension App Extension），以 VPN 形式运行。系统所有流量经过虚拟 TUN 网卡，Shadowrocket 在用户态处理。

### 实现架构

```
┌──────────────────────────────────────────────┐
│ ShadowProxy.app (主 App)                      │
│  - UI、配置管理、启停控制                       │
│  - 通过 NETunnelProviderManager 控制 Extension │
└──────────────┬───────────────────────────────┘
               │ IPC (App Group / XPC)
┌──────────────▼───────────────────────────────┐
│ PacketTunnel.appex (Network Extension)        │
│  - NEPacketTunnelProvider                     │
│  - 读取 TUN 虚拟网卡的 IP 包                   │
│  - TCP/UDP 流重组                              │
│  - DNS 拦截（可选 FakeIP）                     │
│  - 转发到 VMess/SS/DIRECT outbound            │
└──────────────────────────────────────────────┘
```

### 关键模块

#### 1. NEPacketTunnelProvider
- 继承 `NEPacketTunnelProvider`
- `startTunnel()`：配置 TUN 网卡、DNS、路由表
- `packetFlow.readPackets()`：从 TUN 读取 IP 包
- `packetFlow.writePackets()`：将响应写回 TUN

#### 2. IP 包解析与 TCP 重组
- 解析 IPv4/IPv6 头
- 提取 TCP 连接：SYN/ACK/FIN 状态机
- 将 TCP 流转为 byte stream，交给 outbound 处理
- UDP 直接转发（特别是 DNS）

#### 3. DNS 处理
- **方案 A：透明 DNS 转发**：DNS 查询直接转发到远程 DNS（如 8.8.8.8），通过代理加密
- **方案 B：FakeIP**：本地 DNS 返回虚假 IP（198.18.0.0/15），建立 FakeIP→域名 映射，代理时用域名连接远端。优点：域名级别规则匹配更精确

#### 4. 路由表配置
```swift
let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
settings.ipv4Settings = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]  // 捕获所有流量
settings.ipv4Settings?.excludedRoutes = [...]  // 排除本地网段
settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.2"])  // FakeIP DNS
```

#### 5. 签名与权限
- 需要 Apple Developer Account
- App 和 Extension 都需要 `com.apple.developer.networking.networkextension` entitlement
- App Group 共享配置文件
- 开发期间可用 `systemextensionsd` 调试

### 工作量预估
- NEPacketTunnelProvider 骨架 + TUN 配置：4 小时
- IP 包解析 + TCP 重组：8-12 小时（复杂度高）
- DNS 拦截（FakeIP）：4-6 小时
- 与现有 ProxyEngine 集成：4 小时
- 签名/权限/调试：2-4 小时
- **总计：约 20-30 小时**

### 替代方案：lwIP 用户态 TCP 栈
不自己实现 TCP 重组，用 lwIP（轻量 TCP/IP 栈）：
- 从 TUN 读取 IP 包 → 喂给 lwIP
- lwIP 重组 TCP 流 → 回调应用层
- 减少 TCP 状态机实现工作量
- sing-box、Clash Premium 都用这种方案
- Swift 可通过 C bridging 调用 lwIP

---

## Phase 4：性能优化

### 连接池
- 复用 VMess/SS 到代理服务器的 TCP 连接
- 多路复用（VMess 支持 Mux）

### 零拷贝 Relay
- 避免 Data 频繁 alloc/copy
- 使用 `DispatchData` 或 `UnsafeMutableBufferPointer`
- NWConnection 的 `send(content:)` 支持零拷贝

### 并发控制
- 最大并发连接数限制
- 空闲连接超时回收
- 内存压力监控

---

## 优先级建议

1. **Phase 2 分流增强**（最快见效，1-2 天）
2. **Phase 3 TUN 模式**（核心竞争力，1-2 周）
3. **Phase 4 性能优化**（长期迭代）

## 技术决策记录

### VMess 协议实现要点（踩坑总结）
1. KDF 是**递归嵌套 HMAC**：`hmac.New(parent.Create, value)` 模式，不是迭代 HMAC 链
2. AuthID 字段顺序：`[timestamp(8)][random(4)][CRC32(前12字节)(4)]`，random 在 CRC32 前
3. GCM Seal 必须传 **AAD = authID**
4. **connectionNonce(8字节)** 参与 KDF path 并写入 packet（authID 和 encHeader 之间）
5. CryptoKit `sealed.ciphertext` 是 `combined` 的切片（startIndex=12），必须 `Data(sealed.ciphertext)` 拷贝重置
6. 响应头格式：`[AEAD enc length(18)][AEAD enc header(N+16)]`，key/nonce 都用 KDF 派生
7. **option=0x01 最简单可用**：明文 2 字节长度 + GCM payload。0x05 需要 SHAKE-128，0x1D 需要 GlobalPadding
8. 数据加密 nonce 格式：`[count_BE_2bytes][IV[2:12]]`，count 从 0 递增

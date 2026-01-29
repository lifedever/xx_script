# Clash Meta 配置说明

## 解决 Notion 等国外网站无法访问的问题

### 问题原因

国外网站（如 notion.so）无法访问，通常是 **DNS 污染** 导致：
- 国内 DNS 服务器对国外域名返回错误或被污染的 IP
- 即使流量走了代理，但 DNS 解析在本地完成，拿到的是错误 IP

### 解决方案

通过以下三个关键配置解决：

#### 1. 启用 TUN 模式

```yaml
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
    - tcp://any:53
```

**作用**：
- 创建虚拟网卡，接管系统所有流量（不只是浏览器）
- `dns-hijack` 劫持所有 53 端口的 DNS 请求，交给 Clash 处理
- 不再依赖系统代理设置

#### 2. 配置 DNS Fallback

```yaml
dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip

  # 国内 DNS（用于解析国内域名）
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query

  # 国外 DNS（用于解析国外域名）
  fallback:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - tls://8.8.8.8:853
```

**作用**：
- `nameserver`：国内域名用国内 DNS 解析（速度快）
- `fallback`：国外域名用国外 DNS 解析（避免污染）

#### 3. 配置 Fallback 过滤器

```yaml
fallback-filter:
  geoip: true
  geoip-code: CN
  geosite:
    - gfw
  ipcidr:
    - 240.0.0.0/4
```

**作用**：满足以下任一条件时，使用 fallback DNS 解析：

- 解析结果 IP 不在中国（geoip 非 CN）
- 域名在 GFW 列表中
- 解析结果是保留 IP（240.0.0.0/4，通常是被污染的特征）

### 工作流程

```
访问 notion.so
    ↓
TUN 接管流量，dns-hijack 劫持 DNS 请求
    ↓
Clash DNS 处理：notion.so 命中 fallback-filter
    ↓
使用 Cloudflare/Google DNS 解析 → 获得正确 IP
    ↓
匹配规则：DOMAIN-SUFFIX,notion.so → 🚀 代理
    ↓
通过代理节点访问 notion.so ✓
```

### 配置文件结构

```
clash_meta/
└── config.yaml    # 主配置文件
```

### 使用方法

1. 将 `config.yaml` 复制到 Clash Meta 配置目录：
   ```bash
   cp config.yaml ~/.config/clash.meta/config.yaml
   ```

2. 重启 Clash Meta

3. 确保 TUN 模式已启用（可能需要授权管理员权限）

### 订阅配置

当前配置了两个代理订阅：

| 名称 | Provider |
|------|----------|
| 良心云 | `liangxin` |
| Hneko云 | `hneko` |

所有地区节点组会同时从两个订阅拉取节点。

### 分流规则

| 服务 | 策略组 |
|------|--------|
| AI 服务 (OpenAI/Claude/Bing/Copilot) | 🤖 AI |
| Telegram | ✈️ 电报 |
| Google | 🔍 谷歌 |
| Microsoft | 🪟 微软 |
| Apple / 国内网站 | DIRECT |
| 其他国外网站 | 🚀 代理 |
| 未匹配 | 🐟 兜底 |

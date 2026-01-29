# Clash Meta 配置说明

## 功能特性

- TUN 模式接管系统流量
- 多订阅源支持（良心云 + Hneko云）
- 按地区自动分组（香港、台湾、新加坡、日本、韩国、美国）
- 服务分流（AI、Telegram、Google、Microsoft 等）
- 兼容公司 VPN（内网 IP 自动直连）

## 关键配置说明

### 1. TUN 模式

```yaml
tun:
  enable: true
  stack: system
  auto-route: true
  dns-hijack:
    - any:53
    - tcp://any:53
  route-exclude-address:
    - 10.0.0.0/8
    - 172.16.0.0/12
    - 192.168.0.0/16
    - 127.0.0.0/8
    # ...其他内网网段
```

**作用**：
- 创建虚拟网卡接管系统所有流量
- `dns-hijack` 劫持 DNS 请求交给 Clash 处理
- `route-exclude-address` 排除内网 IP，让 VPN 流量正常工作

### 2. DNS 配置

```yaml
dns:
  enable: true
  enhanced-mode: redir-host  # 返回真实 IP，兼容 VPN
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  nameserver-policy:
    '+.manyibar.cn': 'tls://8.8.8.8:853'  # 公司域名用指定 DNS
  fallback:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN
    geosite:
      - gfw
```

**模式说明**：
- `redir-host`：返回真实 IP，对 VPN 兼容性好
- `fake-ip`：返回假 IP，分流更精准但可能和 VPN 冲突

**DNS 分流**：
- 国内域名 → 国内 DNS（阿里、腾讯）
- 国外域名 → 国外 DNS（Cloudflare、Google）
- 公司域名 → 指定 DNS（8.8.8.8 DoT）

### 3. 代理订阅

当前配置了两个订阅源：

| 名称 | Provider |
|------|----------|
| 良心云 | `liangxin` |
| Hneko云 | `hneko` |

所有地区节点组会同时从两个订阅拉取节点。

### 4. 代理组

| 分组 | 类型 | 说明 |
|------|------|------|
| 🚀 代理 | select | 主选择器 |
| ⚡ 自动 | url-test | 自动选最快节点 |
| 🤖 AI | select | AI 服务专用 |
| ✈️ 电报 | select | Telegram 专用 |
| 🔍 谷歌 | select | Google 服务 |
| 🪟 微软 | select | Microsoft（默认直连） |
| 🇭🇰/🇨🇳/🇸🇬/🇯🇵/🇰🇷/🇺🇸 | url-test | 地区节点组 |
| 🐟 兜底 | select | 未匹配规则的流量 |

### 5. 分流规则

| 服务 | 策略 |
|------|------|
| 内网 IP (10.x/172.x/192.168.x) | DIRECT |
| 公司域名 (manyibar.cn 等) | DIRECT |
| Java 进程 | DIRECT |
| AI 服务 (OpenAI/Claude/Bing/Copilot) | 🤖 AI |
| Telegram | ✈️ 电报 |
| Google | 🔍 谷歌 |
| Microsoft | 🪟 微软 |
| Apple | DIRECT |
| 国内网站 | DIRECT |
| 其他国外网站 | 🚀 代理 |

## 使用方法

1. 复制配置文件到 Clash Meta 配置目录：
```bash
cp config.yaml ~/.config/clash.meta/config.yaml
```

2. 重启 Clash Meta

3. 如需修改订阅链接，编辑 `proxy-providers` 部分

## VPN 兼容说明

本配置已针对公司 VPN 做了优化：

1. **DNS 模式**：使用 `redir-host` 而非 `fake-ip`，返回真实 IP
2. **内网排除**：`route-exclude-address` 排除所有内网 IP 段
3. **公司域名**：通过 `nameserver-policy` 指定公司域名的 DNS
4. **进程规则**：Java 进程直连，避免数据库连接问题

如果仍有问题，可尝试在 `/etc/hosts` 添加公司服务器 IP 映射。

## 控制面板

访问 `http://127.0.0.1:9090/ui` 可打开 Clash 控制面板，用于：
- 切换代理节点
- 查看连接日志
- 测试延迟

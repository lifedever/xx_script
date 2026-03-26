#!/usr/bin/env python3
"""
sing-box 配置生成器 (兼容 v1.13+)
用法: cd xx_script/singbox && python3 generate.py

功能:
  - 从 Clash 订阅拉取节点
  - 按地区自动分组 (url-test 自动测速)
  - 按服务分流 (YouTube/Netflix/OpenAI 等)
  - 规则参考 Shadowrocket 配置
  - 支持多订阅
"""

import json, os, re, ssl, sys, urllib.request, uuid

# ============================================================
#  订阅列表 — 从同目录 subscriptions.json 读取 (已 gitignore)
#  首次使用需创建该文件，格式见 subscriptions.example.json
# ============================================================
SUBSCRIPTIONS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "subscriptions.json")

# ============================================================
#  基础设置
# ============================================================
LISTEN_PORT = 7890  # HTTP/SOCKS 混合代理端口
OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(OUTPUT_DIR, "config.json")
RULES_DIR = os.path.join(OUTPUT_DIR, "rules")

# ============================================================
#  地区分组 (url-test 自动测速)
# ============================================================
REGIONS = {
    "🇭🇰香港": r"(?i)(香港|HK|Hong.?Kong|港)",
    "🇨🇳台湾": r"(?i)(台湾|TW|Taiwan|台|臺灣)",
    "🇯🇵日本": r"(?i)(日本|JP|Japan|日|東京)",
    "🇰🇷韩国": r"(?i)(韩国|KR|Korea|韩|首尔|韓國)",
    "🇸🇬新加坡": r"(?i)(新加坡|SG|Singapore|狮城)",
    "🇺🇸美国": r"(?i)(美国|US|USA|United.?States|美|America)",
}

# ============================================================
#  自定义规则列表 (name, url, outbound, type)
#  type: "ruleset" = Surge/Shadowrocket 格式
#        "domainset" = 纯域名列表
# ============================================================
CUSTOM_RULE_LISTS = [
    ("ai-custom", "https://raw.githubusercontent.com/lifedever/xx_script/refs/heads/main/ss/rules/Ai.list", "🤖OpenAI", "ruleset"),
    ("direct-custom", "https://raw.githubusercontent.com/lifedever/xx_script/refs/heads/main/ss/rules/Direct.list", "DIRECT", "ruleset"),
    ("proxy-custom", "https://raw.githubusercontent.com/lifedever/xx_script/refs/heads/main/ss/rules/Proxy.list", "Proxy", "ruleset"),
]


# ============================================================
#  工具函数
# ============================================================
def fetch(url, timeout=30, ua="clash"):
    """下载 URL 内容，sing-box 运行时自动走 HTTP 代理"""
    print(f"  ↓ {url[:80]}...")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    # 检测 sing-box 是否在运行，走 HTTP 代理避免 TUN 兼容问题
    proxy_handler = urllib.request.BaseHandler()
    try:
        import subprocess
        result = subprocess.run(["pgrep", "-f", "sing-box run"], capture_output=True)
        if result.returncode == 0:
            proxy_handler = urllib.request.ProxyHandler({
                "http": f"http://127.0.0.1:{LISTEN_PORT}",
                "https": f"http://127.0.0.1:{LISTEN_PORT}",
            })
    except Exception:
        pass
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx),
        proxy_handler,
    )
    req = urllib.request.Request(url, headers={"User-Agent": ua})
    with opener.open(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def parse_singbox_outbounds(json_text):
    """从 sing-box 原生 JSON 中提取代理节点"""
    d = json.loads(json_text)
    outbounds = []
    skip_types = {"direct", "selector", "urltest", "block", "dns"}
    # 过滤掉信息提示节点 (如 "剩余流量", "套餐到期")
    info_keywords = ["剩余流量", "套餐到期", "不支持", "客户端", "更换", "官网"]
    for ob in d.get("outbounds", []):
        if ob.get("type") in skip_types:
            continue
        tag = ob.get("tag", "")
        if any(kw in tag for kw in info_keywords):
            continue
        outbounds.append(ob)
    return outbounds


def parse_clash_proxies(yaml_text):
    """从 Clash YAML 中解析代理节点，返回 sing-box outbound 列表"""
    try:
        import yaml
    except ImportError:
        os.system(f"{sys.executable} -m pip install pyyaml -q")
        import yaml

    data = yaml.safe_load(yaml_text)
    proxies = data.get("proxies", [])
    outbounds = []

    for p in proxies:
        ptype = p.get("type", "")
        name = p.get("name", "unknown")

        if ptype == "vmess":
            ob = {
                "type": "vmess",
                "tag": name,
                "server": p["server"],
                "server_port": int(p["port"]),
                "uuid": p["uuid"],
                "alter_id": int(p.get("alterId", 0)),
                "security": p.get("cipher", "auto"),
            }
            net = p.get("network", "tcp")
            if net == "ws":
                ob["transport"] = {"type": "ws", "path": p.get("ws-opts", {}).get("path", "/")}
                host = p.get("ws-opts", {}).get("headers", {}).get("Host")
                if host:
                    ob["transport"]["headers"] = {"Host": [host]}
            elif net == "grpc":
                ob["transport"] = {"type": "grpc", "service_name": p.get("grpc-opts", {}).get("grpc-service-name", "")}
            if p.get("tls"):
                ob["tls"] = {"enabled": True, "server_name": p.get("servername", p["server"])}
                if p.get("skip-cert-verify"):
                    ob["tls"]["insecure"] = True
            outbounds.append(ob)

        elif ptype == "ss":
            ob = {
                "type": "shadowsocks",
                "tag": name,
                "server": p["server"],
                "server_port": int(p["port"]),
                "method": p.get("cipher", ""),
                "password": p.get("password", ""),
            }
            # obfs / v2ray 插件
            plugin = p.get("plugin", "")
            plugin_opts = p.get("plugin-opts", {})
            if plugin == "obfs":
                ob["plugin"] = "obfs-local"
                ob["plugin_opts"] = (
                    f"obfs={plugin_opts.get('mode', 'http')}"
                    f";obfs-host={plugin_opts.get('host', '')}"
                )
            elif plugin == "v2ray-plugin":
                ob["plugin"] = "v2ray-plugin"
                opts = f"mode={plugin_opts.get('mode', 'websocket')}"
                if plugin_opts.get("tls"):
                    opts += ";tls"
                if plugin_opts.get("host"):
                    opts += f";host={plugin_opts['host']}"
                if plugin_opts.get("path"):
                    opts += f";path={plugin_opts['path']}"
                ob["plugin_opts"] = opts
            outbounds.append(ob)

        elif ptype == "trojan":
            ob = {
                "type": "trojan",
                "tag": name,
                "server": p["server"],
                "server_port": int(p["port"]),
                "password": p.get("password", ""),
                "tls": {"enabled": True, "server_name": p.get("sni", p["server"])},
            }
            if p.get("skip-cert-verify"):
                ob["tls"]["insecure"] = True
            if p.get("network") == "ws":
                ob["transport"] = {"type": "ws", "path": p.get("ws-opts", {}).get("path", "/")}
            outbounds.append(ob)

        elif ptype in ("hysteria2", "hy2"):
            ob = {
                "type": "hysteria2",
                "tag": name,
                "server": p["server"],
                "server_port": int(p["port"]),
                "password": p.get("password", ""),
                "tls": {"enabled": True, "server_name": p.get("sni", p["server"])},
            }
            if p.get("skip-cert-verify"):
                ob["tls"]["insecure"] = True
            outbounds.append(ob)

        elif ptype == "vless":
            ob = {
                "type": "vless",
                "tag": name,
                "server": p["server"],
                "server_port": int(p["port"]),
                "uuid": p["uuid"],
            }
            if p.get("flow"):
                ob["flow"] = p["flow"]
            if p.get("tls"):
                ob["tls"] = {"enabled": True, "server_name": p.get("servername", p["server"])}
                if p.get("skip-cert-verify"):
                    ob["tls"]["insecure"] = True
                reality = p.get("reality-opts")
                if reality:
                    ob["tls"]["reality"] = {
                        "enabled": True,
                        "public_key": reality.get("public-key", ""),
                        "short_id": reality.get("short-id", ""),
                    }
            net = p.get("network", "tcp")
            if net == "ws":
                ob["transport"] = {"type": "ws", "path": p.get("ws-opts", {}).get("path", "/")}
            elif net == "grpc":
                ob["transport"] = {"type": "grpc", "service_name": p.get("grpc-opts", {}).get("grpc-service-name", "")}
            outbounds.append(ob)

    return outbounds


def parse_ruleset(text):
    """解析 Surge/Shadowrocket 规则列表，转为 sing-box rule_set source JSON"""
    domain_suffix, domain, domain_keyword, ip_cidr = [], [], [], []
    for line in text.splitlines():
        line = line.split("//")[0].split("#")[0].strip()
        if not line or line.startswith(";"):
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2:
            continue
        rtype, value = parts[0].upper(), parts[1]
        if rtype == "DOMAIN-SUFFIX":
            domain_suffix.append(value)
        elif rtype == "DOMAIN":
            domain.append(value)
        elif rtype == "DOMAIN-KEYWORD":
            domain_keyword.append(value)
        elif rtype in ("IP-CIDR", "IP-CIDR6"):
            ip_cidr.append(value)
    rules = []
    if domain_suffix:
        rules.append({"domain_suffix": domain_suffix})
    if domain:
        rules.append({"domain": domain})
    if domain_keyword:
        rules.append({"domain_keyword": domain_keyword})
    if ip_cidr:
        rules.append({"ip_cidr": ip_cidr})
    return {"version": 2, "rules": rules}


def parse_domainset(text):
    """解析纯域名列表 (DOMAIN-SET)"""
    domain_suffix, domain = [], []
    for line in text.splitlines():
        line = line.split("//")[0].split("#")[0].strip()
        if not line:
            continue
        if line.startswith("."):
            domain_suffix.append(line[1:])
        else:
            domain.append(line)
    rules = []
    if domain_suffix:
        rules.append({"domain_suffix": domain_suffix})
    if domain:
        rules.append({"domain": domain})
    return {"version": 2, "rules": rules}


def geosite_rule_set(name, file_name=None):
    """生成远程 geosite rule_set 定义"""
    if file_name is None:
        file_name = f"geosite-{name}"
    return {
        "type": "remote",
        "tag": f"geosite-{name}",
        "format": "binary",
        "url": f"https://testingcf.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/{file_name}.srs",
        "download_detour": "DIRECT",
    }


def geoip_rule_set(name):
    """生成远程 geoip rule_set 定义"""
    return {
        "type": "remote",
        "tag": f"geoip-{name}",
        "format": "binary",
        "url": f"https://testingcf.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-{name}.srs",
        "download_detour": "DIRECT",
    }


# ============================================================
#  主逻辑
# ============================================================
def main():
    os.makedirs(RULES_DIR, exist_ok=True)

    # ---- 0. 加载订阅列表 ----
    if not os.path.exists(SUBSCRIPTIONS_FILE):
        print(f"❌ 未找到订阅文件: {SUBSCRIPTIONS_FILE}")
        print(f"   请复制 subscriptions.example.json 为 subscriptions.json 并填入你的订阅")
        sys.exit(1)
    with open(SUBSCRIPTIONS_FILE, "r", encoding="utf-8") as f:
        subscriptions = json.load(f)

    # ---- 1. 拉取订阅，解析节点 ----
    # 过滤信息提示类假节点
    info_keywords = ["剩余流量", "套餐到期", "不支持", "客户端", "更换", "官网", "过期", "购买"]

    print("📡 拉取订阅...")
    all_nodes = []
    for sub in subscriptions:
        try:
            nodes = []
            # 先尝试 sing-box 原生格式
            try:
                text = fetch(sub["url"], ua="sing-box")
                if text.strip().startswith("{"):
                    nodes = parse_singbox_outbounds(text)
                    if nodes:
                        print(f"  ✓ {sub['name']}: {len(nodes)} 个节点 (sing-box 格式)")
            except Exception:
                pass
            # 再尝试 Clash 格式
            if not nodes:
                text = fetch(sub["url"], ua="ClashforWindows")
                nodes = parse_clash_proxies(text)
                # 过滤假节点
                nodes = [n for n in nodes if not any(kw in n.get("tag", "") for kw in info_keywords)]
                if nodes:
                    print(f"  ✓ {sub['name']}: {len(nodes)} 个节点 (Clash 格式)")
                else:
                    print(f"  ⚠ {sub['name']}: 无有效节点")
            for n in nodes:
                all_nodes.append((n["tag"], n, sub["name"]))
        except Exception as e:
            print(f"  ✗ {sub['name']}: {e}")

    if not all_nodes:
        print("❌ 没有获取到任何节点，退出")
        sys.exit(1)

    all_tags = [t[0] for t in all_nodes]

    # ---- 2. 构建地区分组 ----
    region_groups = {}
    matched_tags = set()
    for region_name, pattern in REGIONS.items():
        tags = [tag for tag in all_tags if re.search(pattern, tag)]
        region_groups[region_name] = tags
        matched_tags.update(tags)
        print(f"  {region_name}: {len(tags)} 个节点")

    other_tags = [tag for tag in all_tags if tag not in matched_tags]
    region_groups["🌍其他"] = other_tags
    print(f"  🌍其他: {len(other_tags)} 个节点")
    region_names = list(REGIONS.keys()) + ["🌍其他"]

    # ---- 3. 下载自定义规则列表 ----
    print("\n📋 下载自定义规则列表...")
    custom_rule_set_defs = []
    custom_route_rules = []

    for name, url, outbound, rtype in CUSTOM_RULE_LISTS:
        json_path = os.path.join(RULES_DIR, f"{name}.json")
        try:
            text = fetch(url)
            rs = parse_domainset(text) if rtype == "domainset" else parse_ruleset(text)
            if not rs["rules"]:
                print(f"  ⚠ {name}: 无有效规则，跳过")
                continue
            with open(json_path, "w", encoding="utf-8") as f:
                json.dump(rs, f, ensure_ascii=False)
            custom_rule_set_defs.append({
                "type": "local",
                "tag": name,
                "format": "source",
                "path": json_path,
            })
            if outbound in ("DIRECT", "REJECT"):
                custom_route_rules.append({
                    "rule_set": [name],
                    "action": "route",
                    "outbound": outbound if outbound == "DIRECT" else None,
                })
                if outbound == "REJECT":
                    custom_route_rules[-1] = {"rule_set": [name], "action": "reject"}
            else:
                custom_route_rules.append({
                    "rule_set": [name],
                    "action": "route",
                    "outbound": outbound,
                })
            print(f"  ✓ {name}")
        except Exception as e:
            print(f"  ✗ {name}: {e}")

    # ---- 4. 组装 sing-box 1.13 配置 ----
    print("\n⚙️  生成配置...")

    available_regions = [r for r in region_names if region_groups[r]]

    # --- Outbounds ---
    outbounds = []

    # DIRECT
    outbounds.append({"type": "direct", "tag": "DIRECT"})

    # 预处理订阅组和地区组数据
    sub_group_names = []
    sub_nodes = {}
    for tag, ob, sub_name in all_nodes:
        sub_nodes.setdefault(sub_name, []).append(tag)
    for sub_name, tags in sub_nodes.items():
        group_tag = f"📦{sub_name}"
        sub_group_names.append(group_tag)
        print(f"  📦 {sub_name}: {len(tags)} 个节点")

    # ---- 面板排列顺序 ----

    # 1. Proxy 主选择
    outbounds.append({
        "type": "selector",
        "tag": "Proxy",
        "outbounds": sub_group_names + available_regions + all_tags,
        "default": sub_group_names[0] if sub_group_names else (available_regions[0] if available_regions else all_tags[0]),
    })

    # 2. 订阅组
    for sub_name, tags in sub_nodes.items():
        group_tag = f"📦{sub_name}"
        outbounds.append({
            "type": "selector",
            "tag": group_tag,
            "outbounds": tags,
        })

    # 3. 服务分流组
    service_outbounds = ["Proxy"] + sub_group_names + available_regions
    services = [
        ("🤖OpenAI", [o for o in available_regions if o != "🇭🇰香港"] + sub_group_names + ["Proxy"]),
        ("🔍Google", service_outbounds),
        ("▶️YouTube", service_outbounds),
        ("🎬Netflix", service_outbounds),
        ("🏰Disney", service_outbounds),
        ("🎵TikTok", service_outbounds),
        ("💻Microsoft", service_outbounds),
        ("📝Notion", service_outbounds),
        ("🍎Apple", ["DIRECT"] + service_outbounds),
    ]
    for svc_name, svc_outs in services:
        outbounds.append({
            "type": "selector",
            "tag": svc_name,
            "outbounds": svc_outs,
        })

    # 3. 漏网之鱼
    outbounds.append({
        "type": "selector",
        "tag": "🐟漏网之鱼",
        "outbounds": ["Proxy", "DIRECT"] + sub_group_names + available_regions,
        "default": "Proxy",
    })

    # 4. 地区组
    for region_name in region_names:
        tags = region_groups[region_name]
        if tags:
            outbounds.append({
                "type": "selector",
                "tag": region_name,
                "outbounds": tags,
            })

    # 6. 代理节点
    for tag, ob, sub_name in all_nodes:
        outbounds.append(ob)

    # --- DNS (v1.13 新格式) ---
    dns = {
        "servers": [
            {"type": "hosts", "tag": "hosts"},
            {
                "type": "https",
                "tag": "dns_proxy",
                "server": "8.8.8.8",
                "detour": "Proxy",
            },
            {
                "type": "local",
                "tag": "dns_local",
            },
            {
                "type": "udp",
                "tag": "dns_direct",
                "server": "223.5.5.5",
            },
            {
                "type": "fakeip",
                "tag": "dns_fakeip",
                "inet4_range": "198.18.0.0/15",
            },
        ],
        "rules": [
            {"ip_accept_any": True, "action": "route", "server": "hosts"},
            {"clash_mode": "Direct", "action": "route", "server": "dns_direct"},
            {"clash_mode": "Global", "action": "route", "server": "dns_proxy"},
            {
                "domain_suffix": [
                    "manyibar.cn", "manyibar.com", "manyiba.com", "kanasinfo.cn",
                    "local", "localhost", "internal",
                ],
                "action": "route",
                "server": "dns_direct",
            },
            {
                "rule_set": ["geosite-ads"],
                "action": "reject",
            },
            {
                "rule_set": ["geosite-cn", "geosite-apple-cn", "geosite-microsoft-cn", "geosite-google-cn"],
                "action": "route",
                "server": "dns_direct",
            },
            {
                "query_type": ["A", "AAAA"],
                "action": "route",
                "server": "dns_fakeip",
            },
        ],
        "final": "dns_proxy",
        "strategy": "ipv4_only",
        "independent_cache": True,
    }

    # --- Inbounds ---
    inbounds = [
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": LISTEN_PORT,
        },
        {
            "type": "tun",
            "tag": "tun-in",
            "address": "172.19.0.1/30",
            "auto_route": True,
            "strict_route": True,
            "stack": "mixed",
        },
    ]

    # --- Route rules (v1.13: action-based) ---
    route_rules = [
        # 1. 必须先 sniff
        {"action": "sniff"},
        # 2. DNS 劫持 (逻辑 OR: protocol=dns 或 port=53)
        {
            "type": "logical",
            "mode": "or",
            "rules": [{"protocol": "dns"}, {"port": 53}],
            "action": "hijack-dns",
        },
        # 3. 私有地址直连
        {"ip_is_private": True, "action": "route", "outbound": "DIRECT"},
        # 4. 防泄漏: 拒绝 DoT 和 STUN
        {
            "type": "logical",
            "mode": "or",
            "rules": [{"port": 853}, {"protocol": "stun"}],
            "action": "reject",
        },
        # 5. 内网/自有域名直连 (绕过代理，走本地 DNS 正常解析)
        {
            "domain_suffix": [
                "manyibar.cn", "manyibar.com", "manyiba.com", "kanasinfo.cn",
                "local", "localhost", "internal",
                "miwifi.com", "hiwifi.com", "leike.cc", "phicomm.me",
                "peiluyou.com", "my.router", "p.to", "rou.ter",
            ],
            "action": "route",
            "outbound": "DIRECT",
        },
        # 6. Clash 模式切换
        {"clash_mode": "Direct", "action": "route", "outbound": "DIRECT"},
        {"clash_mode": "Global", "action": "route", "outbound": "Proxy"},
        # 7. 广告拦截
        {"rule_set": ["geosite-ads"], "action": "reject"},
    ]

    # 7. 自定义规则 (xx_script)
    route_rules.extend(custom_route_rules)

    # 8. 服务分流
    route_rules.extend([
        {"rule_set": ["geosite-openai", "geosite-anthropic", "geosite-category-ai-chat-!cn"], "action": "route", "outbound": "🤖OpenAI"},
        {"rule_set": ["geosite-youtube"], "action": "route", "outbound": "▶️YouTube"},
        {"rule_set": ["geosite-netflix"], "action": "route", "outbound": "🎬Netflix"},
        {"rule_set": ["geosite-disney"], "action": "route", "outbound": "🏰Disney"},
        {"rule_set": ["geosite-tiktok"], "action": "route", "outbound": "🎵TikTok"},
        {"rule_set": ["geosite-google"], "action": "route", "outbound": "🔍Google"},
        {"rule_set": ["geosite-github", "geosite-microsoft"], "action": "route", "outbound": "💻Microsoft"},
        {"rule_set": ["geosite-notion"], "action": "route", "outbound": "📝Notion"},
        {"rule_set": ["geosite-apple"], "action": "route", "outbound": "🍎Apple"},
        # 9. 非中国域名走代理
        {"rule_set": ["geosite-geolocation-!cn"], "action": "route", "outbound": "Proxy"},
        # 10. 中国域名/IP 直连
        {"rule_set": ["geosite-cn", "geoip-cn"], "action": "route", "outbound": "DIRECT"},
    ])

    # --- Rule sets ---
    rule_set_defs = custom_rule_set_defs + [
        geosite_rule_set("ads", "geosite-category-ads-all"),
        geosite_rule_set("cn"),
        geosite_rule_set("apple-cn", "geosite-apple@cn"),
        geosite_rule_set("microsoft-cn", "geosite-microsoft@cn"),
        geosite_rule_set("google-cn", "geosite-google@cn"),
        geosite_rule_set("openai"),
        geosite_rule_set("anthropic"),
        geosite_rule_set("category-ai-chat-!cn"),
        geosite_rule_set("youtube"),
        geosite_rule_set("netflix"),
        geosite_rule_set("disney"),
        geosite_rule_set("tiktok"),
        geosite_rule_set("google"),
        geosite_rule_set("github"),
        geosite_rule_set("microsoft"),
        geosite_rule_set("notion"),
        geosite_rule_set("apple"),
        geosite_rule_set("geolocation-!cn"),
        geoip_rule_set("cn"),
    ]

    # --- 完整配置 ---
    config = {
        "log": {"level": "info", "timestamp": True},
        "experimental": {
            "cache_file": {
                "enabled": True,
                "path": os.path.join(OUTPUT_DIR, "cache.db"),
                "store_fakeip": True,
                "store_rdrc": True,
            },
            "clash_api": {
                "external_controller": "127.0.0.1:9091",
                "secret": "",
                "default_mode": "rule",
            },
        },
        "dns": dns,
        "ntp": {
            "enabled": True,
            "server": "time.apple.com",
            "server_port": 123,
            "interval": "30m",
            "detour": "DIRECT",
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "rules": route_rules,
            "rule_set": rule_set_defs,
            "final": "🐟漏网之鱼",
            "auto_detect_interface": True,
            "default_domain_resolver": "dns_local",
        },
    }

    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(config, f, ensure_ascii=False, indent=2)

    print(f"\n✅ 配置已生成: {CONFIG_FILE}")
    print(f"   节点: {len(all_nodes)} 个")
    print(f"   地区组: {len(available_regions)} 个")
    print(f"   规则集: {len(rule_set_defs)} 个")
    print(f"   代理端口: {LISTEN_PORT}")
    print(f"   Clash API: http://127.0.0.1:9091")
    print(f"\n🚀 启动命令:")
    print(f"   # 验证配置")
    print(f"   sing-box check -c {CONFIG_FILE}")
    print(f"\n   # HTTP 代理模式 (端口 {LISTEN_PORT})")
    print(f"   sing-box run -c {CONFIG_FILE}")
    print(f"\n   # TUN 全局模式 (需要 sudo)")
    print(f"   sudo sing-box run -c {CONFIG_FILE}")


if __name__ == "__main__":
    main()

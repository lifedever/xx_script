/**
 * Clash 配置转换脚本
 */
function main(config) {
    // 代理组配置
    config["proxy-groups"] = [
        // 主代理选择
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/Static.png",
            "include-all": true,
            "exclude-filter":
                "(?i)GB|Traffic|Expire|Premium|频道|订阅|ISP|流量|到期|重置",
            name: "🚀 代理",
            type: "select",
            proxies: [
                "⚡ 自动",
                "🇭🇰 香港",
                "🇸🇬 新加坡",
                "🇯🇵 日本",
                "🇺🇸 美国",
                "🌏 其他国家",
            ],
        },
        // 自动选择最快节点
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/Urltest.png",
            "include-all": true,
            "exclude-filter":
                "(?i)GB|Traffic|Expire|Premium|频道|订阅|ISP|流量|到期|重置",
            name: "⚡ 自动",
            type: "url-test",
            interval: 3600,
        },
        // AI 服务专用
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/OpenAI.png",
            name: "🤖 AI",
            type: "select",
            proxies: [
                "🚀 代理",
                "DIRECT",
                "🐟 漏网之鱼",
                "🇭🇰 香港",
                "🇸🇬 新加坡",
                "🇯🇵 日本",
                "🇺🇸 美国",
                "🌏 其他国家",
            ],
        },
        // Telegram 专用
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/Telegram.png",
            name: "✈️ 电报",
            type: "select",
            proxies: [
                "🚀 代理",
                "DIRECT",
                "🐟 漏网之鱼",
                "🇭🇰 香港",
                "🇸🇬 新加坡",
                "🇯🇵 日本",
                "🇺🇸 美国",
                "🌏 其他国家",
            ],
        },
        // Google 服务专用
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/Google.png",
            name: "🔍 谷歌",
            type: "select",
            proxies: [
                "🚀 代理",
                "DIRECT",
                "🐟 漏网之鱼",
                "🇭🇰 香港",
                "🇸🇬 新加坡",
                "🇯🇵 日本",
                "🇺🇸 美国",
                "🌏 其他国家",
            ],
        },
        // Microsoft 服务专用
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/Microsoft.png",
            name: "🪟 微软",
            type: "select",
            proxies: [
                "🚀 代理",
                "DIRECT",
                "🐟 漏网之鱼",
                "🇭🇰 香港",
                "🇸🇬 新加坡",
                "🇯🇵 日本",
                "🇺🇸 美国",
                "🌏 其他国家",
            ],
        },
        // Notion 专用
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/Notion.png",
            name: "📝 Notion",
            type: "select",
            proxies: [
                "🚀 代理",
                "DIRECT",
                "🐟 漏网之鱼",
                "🇭🇰 香港",
                "🇸🇬 新加坡",
                "🇯🇵 日本",
                "🇺🇸 美国",
                "🌏 其他国家",
            ],
        },
        // 漏网之鱼（兜底）
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/Final.png",
            name: "🐟 漏网之鱼",
            type: "select",
            proxies: [
                "🚀 代理",
                "DIRECT",
                "⚡ 自动",
                "🇭🇰 香港",
                "🇸🇬 新加坡",
                "🇯🇵 日本",
                "🇺🇸 美国",
                "🌏 其他国家",
            ],
        },
        // 订阅信息
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/GLaDOS.png",
            "include-all": true,
            filter: "(?i)GB|Traffic|Expire|Premium|频道|订阅|ISP|流量|到期|重置",
            name: "ℹ️ 订阅信息",
            type: "select",
        },
        // 地区节点组
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/HK.png",
            "include-all": true,
            "exclude-filter":
                "(?i)GB|Traffic|Expire|Premium|频道|订阅|ISP|流量|到期|重置",
            filter: "(?i)香港|Hong Kong|HK|🇭🇰",
            name: "🇭🇰 香港",
            type: "url-test",
            interval: 3600,
        },
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/SG.png",
            "include-all": true,
            "exclude-filter":
                "(?i)GB|Traffic|Expire|Premium|频道|订阅|ISP|流量|到期|重置",
            filter: "(?i)新加坡|Singapore|🇸🇬",
            name: "🇸🇬 新加坡",
            type: "url-test",
            interval: 3600,
        },
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/JP.png",
            "include-all": true,
            "exclude-filter":
                "(?i)GB|Traffic|Expire|Premium|频道|订阅|ISP|流量|到期|重置",
            filter: "(?i)日本|Japan|🇯🇵",
            name: "🇯🇵 日本",
            type: "url-test",
            interval: 3600,
        },
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/US.png",
            "include-all": true,
            "exclude-filter":
                "(?i)GB|Traffic|Expire|Premium|频道|订阅|ISP|流量|到期|重置",
            filter: "(?i)美国|USA|🇺🇸",
            name: "🇺🇸 美国",
            type: "url-test",
            interval: 3600,
        },
        {
            icon: "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color/UN.png",
            "include-all": true,
            "exclude-filter":
                "(?i)GB|Traffic|Expire|Premium|频道|订阅|ISP|流量|到期|重置",
            filter:
                "^(?!.*(香港|Hong Kong|HK|🇭🇰|新加坡|Singapore|🇸🇬|日本|Japan|🇯🇵|美国|USA|🇺🇸)).*$",
            name: "🌏 其他国家",
            type: "url-test",
            interval: 3600,
        },
    ];

    // 规则提供者配置
    if (!config["rule-providers"]) {
        config["rule-providers"] = {};
    }

    config["rule-providers"] = Object.assign(config["rule-providers"], {
        my_private: {
            url: "https://raw.githubusercontent.com/lifedever/xx_script/refs/heads/main/clash/rules/Private.yaml",
            path: "./ruleset/my_private.yaml",
            behavior: "domain",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        private: {
            url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/private.yaml",
            path: "./ruleset/private.yaml",
            behavior: "domain",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        apple: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Apple/Apple.yaml",
            path: "./ruleset/apple.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        cn_domain: {
            url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/cn.yaml",
            path: "./ruleset/cn_domain.yaml",
            behavior: "domain",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        telegram_domain: {
            url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/telegram.yaml",
            path: "./ruleset/telegram_domain.yaml",
            behavior: "domain",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        google_domain: {
            url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/google.yaml",
            path: "./ruleset/google_domain.yaml",
            behavior: "domain",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        "geolocation-!cn": {
            url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/geolocation-!cn.yaml",
            path: "./ruleset/geolocation-!cn.yaml",
            behavior: "domain",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        cn_ip: {
            url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/cn.yaml",
            path: "./ruleset/cn_ip.yaml",
            behavior: "ipcidr",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        telegram_ip: {
            url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/telegram.yaml",
            path: "./ruleset/telegram_ip.yaml",
            behavior: "ipcidr",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        google_ip: {
            url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/google.yaml",
            path: "./ruleset/google_ip.yaml",
            behavior: "ipcidr",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        microsoft_domain: {
            url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/microsoft.yaml",
            path: "./ruleset/microsoft_domain.yaml",
            behavior: "domain",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        microsoft: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Microsoft/Microsoft.yaml",
            path: "./ruleset/microsoft.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        // AI 服务规则
        bing: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Bing/Bing.yaml",
            path: "./ruleset/bing.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        copilot: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Copilot/Copilot.yaml",
            path: "./ruleset/copilot.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        claude: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Claude/Claude.yaml",
            path: "./ruleset/claude.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        bard: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/BardAI/BardAI.yaml",
            path: "./ruleset/bard.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        openai: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/OpenAI/OpenAI.yaml",
            path: "./ruleset/openai.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        steam: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Steam/Steam.yaml",
            path: "./ruleset/steam.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        cloudflare: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Cloudflare/Cloudflare.yaml",
            path: "./ruleset/cloudflare.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        // 自定义规则
        my_ai: {
            url: "https://raw.githubusercontent.com/lifedever/xx_script/refs/heads/main/clash/rules/Ai.yaml",
            path: "./ruleset/my_ai.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        // 自定义规则
        my_proxy: {
            url: "https://raw.githubusercontent.com/lifedever/xx_script/refs/heads/main/clash/rules/Proxy.yaml",
            path: "./ruleset/my_proxy.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
        notion: {
            url: "https://testingcf.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Notion/Notion.yaml",
            path: "./ruleset/notion.yaml",
            behavior: "classical",
            interval: 86400,
            format: "yaml",
            type: "http",
        },
    });

    // 路由规则配置
    config["rules"] = [
        "RULE-SET,my_private,DIRECT",
        "RULE-SET,private,DIRECT",
        "RULE-SET,apple,DIRECT",
        "RULE-SET,my_ai,🤖 AI",
        "RULE-SET,my_proxy,🚀 代理",
        "RULE-SET,bing,🤖 AI",
        "RULE-SET,copilot,🤖 AI",
        "RULE-SET,bard,🤖 AI",
        "RULE-SET,openai,🤖 AI",
        "RULE-SET,claude,🤖 AI",
        "RULE-SET,steam,🚀 代理",
        "RULE-SET,cloudflare,🚀 代理",
        "RULE-SET,telegram_domain,✈️ 电报",
        "RULE-SET,telegram_ip,✈️ 电报",
        "RULE-SET,google_domain,🔍 谷歌",
        "RULE-SET,google_ip,🔍 谷歌",
        "RULE-SET,microsoft_domain,🪟 微软",
        "RULE-SET,microsoft,🪟 微软",
        "RULE-SET,notion,📝 Notion",
        "RULE-SET,geolocation-!cn,🚀 代理",
        "RULE-SET,cn_domain,DIRECT",
        "RULE-SET,cn_ip,DIRECT",
        "MATCH,🐟 漏网之鱼",
    ];

    return config;
}

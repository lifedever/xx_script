/**
 * Clash 配置转换脚本（Sub-Store / Stash / Clash Party 等可加载）
 *
 * 主要功能：
 *   - 注入 proxy-groups：主入口（🚀代理 / ⚡自动）、机场组（📦，动态生成）、
 *     服务分组（🤖AI / ✈️电报 / 🔍谷歌 / 🪟微软 / 📝Notion / 🍎Apple）、
 *     兜底（🐟漏网之鱼）、订阅信息（ℹ️）
 *   - 注入 rule-providers：拉取 MetaCubeX/blackmatrix7 第三方规则集，
 *     以及本仓库自定义 Ai.yaml / Proxy.yaml / Direct.yaml
 *   - 注入 rules：按"私有 → 自定义 → 服务 → 国别 → MATCH"次序分流
 *   - 服务分组只允许在「代理 / 直连 / 漏网之鱼 / 机场」之间选择，避免
 *     上层组互相循环引用
 *
 * 机场组约定（重要）：
 *   机场组由 config["proxy-providers"] 的 key 运行时枚举生成，本文件
 *   **不硬编码任何订阅名单，也绝不能写入订阅 URL / token** —— 本仓库是
 *   公开仓库，订阅链接一旦进来等同于公开发布。proxy-providers 请在
 *   Clash 客户端的「本地覆写」里定义（模板见 clash/local-providers.example.yaml）。
 *   未检测到 proxy-providers 时自动降级为「📦 节点」平铺模式，不会断网。
 *
 * 维护约定：每次修改本文件 → 版本号递增（SemVer），并在 Changelog 顶部
 *           追加一项简述变更。
 *
 * @version 1.5.0
 *
 * Changelog:
 *   1.5.0 (2026-09-06)
 *     - 删除全部 5 个地区组（🇭🇰 / 🇸🇬 / 🇯🇵 / 🇺🇸 / 🌏其他）。原「🌏 其他国家」
 *       会把台湾/韩国/印度/尼日利亚/巴西等 22 个节点混在一起做 url-test，
 *       自动选路结果不可预期
 *     - 改为「按机场分组」：从 proxy-providers 动态生成 📦<机场名> 组，
 *       🚀代理 与各服务组指向机场组而非具体节点 —— 切换机场内部节点时
 *       上层选择不再失效（对齐 Surge 的策略组模型）
 *     - 🚀 代理 去掉 include-all，不再直接平铺节点名，只列机场组
 *     - 删除「⚡ 自动」与常驻的「📦 节点」两个组，精简层级。注意：这意味着
 *       配置里不再有任何 url-test 组，节点失效不会自动切换，需手动换
 *     - 「📦 节点」保留为**降级兜底**：仅在未配置 proxy-providers 时生成，
 *       否则 🚀代理 会变成空组，mihomo 拒绝启动导致整个代理不可用
 *     - 信息节点过滤补充「防失联 / 官网」关键词（此前 `【防失联】：xxx`
 *       会作为可选节点出现在每个组里）
 *
 *   1.4.0 (2026-05-26)
 *     - my_private rule-provider 改引用 clash/rules/Direct.yaml
 *       （behavior: classical），与 surge/ss/singbox 三端共用同一份直连源
 *     - Direct.yaml 同时包含自有域名 + IP-CIDR，原 Private.yaml 失去引用
 *
 *   1.3.0 (2026-05-26)
 *     - 新增「🍎 Apple」代理组（默认 DIRECT，可切 🚀代理 / 漏网之鱼 / 节点 /
 *       地区池），对齐 ss/shadowrocket.conf 的 `🍎Apple = select,DIRECT,Proxy`
 *     - apple rule-set 的出站从硬编码 DIRECT 改为 🍎 Apple，用户可手动切换
 *
 *   1.2.0 (2026-05-26)
 *     - 新增「📦 节点」分组：include-all 兜底所有真节点（仅排除信息节点），
 *       作为地区组 filter 漏判时的安全网，也方便直接挑具体节点
 *     - 「📦 节点」加进 🚀 代理 / 5 个服务组 / 🐟 漏网之鱼 的 proxies
 *
 *   1.1.0 (2026-05-26)
 *     - exclude-filter / 订阅信息 filter 去掉 `GB` 关键词，避免节点名含
 *       `249.25GB` 这种流量额度的单节点订阅被误判为信息节点
 *     - 4 个地区组（HK/SG/JP/US）的 filter 加上短码匹配（hk/sg/jp/us），
 *       适配 `jp-lifedever-xxx` 这种"短码 + 套餐名"风格的单节点拼车
 *     - 🌏 其他国家 的反向 lookahead 同步加上短码排除
 *
 *   1.0.0 (2026-05-20)
 *     - 地区精简到 5 个：HK / SG / JP / US / 其他（去掉 TW / KR）
 *     - 服务组（AI / 电报 / 谷歌 / 微软 / Notion）统一加入 🚀代理 / DIRECT / 🐟漏网之鱼
 *     - 🐟 兜底 改名 🐟 漏网之鱼，MATCH 同步
 *     - 排序：主入口 → 服务组 → 漏网之鱼 → 订阅信息 → 地区池
 *     - 「🌏 其他国家」filter 加 (?i)，避免与地区组双重匹配小写节点
 *     - 文件改名：代理转换.js → proxy-transformer.js
 */
const ICON = "https://testingcf.jsdelivr.net/gh/Orz-3/mini@master/Color";

// 信息节点（流量 / 到期 / 防失联公告）关键词——这些不是真节点，要从所有可选组里剔除
const INFO_FILTER =
    "(?i)剩余流量|套餐|Traffic|Expire|Premium|频道|订阅|ISP|流量|到期|重置|防失联|官网";

function main(config) {
    // ---- 机场组：从 proxy-providers 运行时枚举，不硬编码订阅名单 ----
    // 本地覆写负责注入 proxy-providers（含订阅 URL / token），本文件保持公开可分享
    const providerNames = Object.keys(config["proxy-providers"] || {});

    // 一家机场一个组；没配 proxy-providers 时退回单个「📦 节点」全量池。
    // 这个兜底不是可选项：上层组的 proxies 全部由机场组构成，机场组为空
    // 会让 🚀 代理 变成空组，mihomo 直接拒绝启动 → 整个代理不可用
    const airportGroupDefs = providerNames.length
        ? providerNames.map((name) => ({
              icon: `${ICON}/Available.png`,
              name: `📦 ${name}`,
              type: "select",
              use: [name],
              "exclude-filter": INFO_FILTER,
          }))
        : [
              {
                  icon: `${ICON}/Available.png`,
                  name: "📦 节点",
                  type: "select",
                  "include-all": true,
                  "exclude-filter": INFO_FILTER,
              },
          ];
    const airportGroups = airportGroupDefs.map((g) => g.name);

    // 服务组的可选下游：代理 / 直连 / 兜底 / 各机场
    // 只向下引用（Layer 3 → Layer 2 → Layer 1 → Layer 0），不会形成环
    const serviceOutbounds = ["🚀 代理", "DIRECT", "🐟 漏网之鱼", ...airportGroups];

    // 服务分组模板——除 🍎 Apple 默认直连外，其余结构一致
    const serviceGroup = (name, icon) => ({
        icon: `${ICON}/${icon}.png`,
        name,
        type: "select",
        proxies: serviceOutbounds,
    });

    config["proxy-groups"] = [
        // ---- 主入口 ----
        // 只列 自动 / 机场组 / 节点池，不直接平铺节点名：
        // 这样机场内部换节点时，指向 🚀 代理 的上层组不受影响
        {
            icon: `${ICON}/Static.png`,
            name: "🚀 代理",
            type: "select",
            proxies: [...airportGroups],
        },

        // ---- 机场组（每个 proxy-provider 一个，动态生成）----
        ...airportGroupDefs,

        // ---- 服务分组 ----
        serviceGroup("🤖 AI", "OpenAI"),
        serviceGroup("✈️ 电报", "Telegram"),
        serviceGroup("🔍 谷歌", "Google"),
        serviceGroup("🪟 微软", "Microsoft"),
        serviceGroup("📝 Notion", "Notion"),
        // Apple 默认直连（海外 Apple ID / 商店需要时再切代理）
        {
            icon: `${ICON}/Apple.png`,
            name: "🍎 Apple",
            type: "select",
            proxies: ["DIRECT", "🚀 代理", "🐟 漏网之鱼", ...airportGroups],
        },

        // ---- 兜底 ----
        {
            icon: `${ICON}/Final.png`,
            name: "🐟 漏网之鱼",
            type: "select",
            proxies: ["🚀 代理", "DIRECT", ...airportGroups],
        },

        // ---- 订阅信息（流量 / 到期，仅作展示）----
        {
            icon: `${ICON}/GLaDOS.png`,
            "include-all": true,
            filter: INFO_FILTER,
            name: "ℹ️ 订阅信息",
            type: "select",
        },
    ];

    // 规则提供者配置
    if (!config["rule-providers"]) {
        config["rule-providers"] = {};
    }

    config["rule-providers"] = Object.assign(config["rule-providers"], {
        my_private: {
            url: "https://raw.githubusercontent.com/lifedever/xx_script/refs/heads/main/clash/rules/Direct.yaml",
            path: "./ruleset/my_private.yaml",
            behavior: "classical",
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
        "RULE-SET,apple,🍎 Apple",
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

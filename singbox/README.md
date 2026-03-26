# sing-box 配置生成器

从 Clash 订阅自动生成 sing-box v1.13+ 客户端配置。

## 功能

- 支持多订阅源（Clash 格式）
- 按地区自动分组（香港/台湾/日本/韩国/新加坡/美国/其他）+ url-test 自动测速
- 按服务分流（YouTube/Netflix/Disney/TikTok/Google/Microsoft/OpenAI/Notion/Apple）
- 自定义规则（`../ss/rules/` 下的 Ai/Direct/Proxy 规则）
- 广告拦截 + 国内直连 + FakeIP
- HTTP/SOCKS 混合代理 + TUN 全局模式

## 使用

```bash
# 1. 安装 sing-box
brew install sing-box

# 2. 配置订阅
cp subscriptions.example.json subscriptions.json
# 编辑 subscriptions.json，填入你的 Clash 订阅链接

# 3. 生成配置
python3 generate.py

# 4. 启动
# HTTP 代理模式（端口 7890）
sing-box run -c config.json

# TUN 全局模式（需要 sudo）
sudo sing-box run -c config.json
```

## 订阅格式

`subscriptions.json`（已 gitignore，不会提交）：

```json
[
  {"name": "机场A", "url": "https://xxx?clash=1"},
  {"name": "机场B", "url": "https://yyy?clash=1"}
]
```

## 依赖

- Python 3 + PyYAML（脚本会自动安装）
- sing-box 1.13+

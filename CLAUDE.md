# 项目：xx_script

## 概述

这是一个代理软件规则配置项目，支持 Clash、Surge、Shadowrocket 等工具。

## 项目结构

```text
.
├── deploy.sh          # 部署脚本
├── clash/             # Clash 配置
│   ├── rules/         # Clash 规则文件
│   │   ├── Ai.yaml        # AI 相关规则
│   │   ├── Proxy.yaml     # 代理规则
│   │   ├── Direct.yaml    # 直连规则
│   │   └── Private.yaml   # 私有规则
│   └── 代理转换.js     # 代理转换脚本
├── module/            # Surge 模块
│   ├── common_always_real_ip.sgmodule
│   └── exclude_reservered_ip.sgmodule
├── ss/                # Shadowrocket 配置
│   ├── rules/         # Shadowrocket 规则文件
│   │   ├── Ai.list        # AI 相关规则
│   │   ├── Proxy.list     # 代理规则
│   │   └── Direct.list    # 直连规则
│   └── shadowrocket.conf
└── surge/             # Surge 配置
    └── rules/         # Surge 规则文件
        ├── Ai.list        # AI 相关规则
        ├── Proxy.list     # 代理规则
        └── Direct.list    # 直连规则
```

## 规则文件说明

规则文件按工具分目录存放：

- **Shadowrocket (ss/rules/)**: 使用 `.list` 格式
- **Surge (surge/rules/)**: 使用 `.list` 格式
- **Clash (clash/rules/)**: 使用 `.yaml` 格式（需要 `payload:` 包裹）

### 当前规则分类

- `Ai.list/yaml` - AI 相关服务规则
- `Proxy.list/yaml` - 代理规则
- `Direct.list/yaml` - 直连规则（包含 manyibar.cn、kanasinfo.cn、manyibar.com、manyiba.com 及相关 IP）
- `Private.yaml` - Clash 私有规则

## 规则格式

- `DOMAIN-SUFFIX,example.com` - 匹配域名后缀
- `IP-CIDR,x.x.x.x/xx` - 匹配 IP 地址段
- `PROCESS-NAME,AppName` - 匹配进程名称

### Clash 特殊格式

Clash 规则需要使用 YAML 格式，每条规则前需要加 `-` 前缀，并包裹在 `payload:` 下

## 开发指南

- 按类别整理规则
- 为不明显的规则添加注释
- 修改规则列表时更新日期注释
- 部署前测试规则

## 部署

运行 `./deploy.sh` 提交并推送更改到仓库。

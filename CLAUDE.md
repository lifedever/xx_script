# 项目：xx_script

## 概述

这是一个代理软件规则配置项目，支持 Clash、Surge、Shadowrocket 等工具。

## 项目结构

```text
.
├── General.list       # 通用代理规则（域名后缀、IP-CIDR、进程）
├── Rules.list         # 附加规则
├── deploy.sh          # 部署脚本
├── clash/             # Clash 配置
│   ├── rules/         # Clash 规则文件
│   └── 代理转换.js     # 代理转换脚本
├── module/            # Surge 模块
│   ├── common_always_real_ip.sgmodule
│   └── exclude_reservered_ip.sgmodule
├── ss/                # Shadowrocket 配置
│   ├── rules/         # Shadowrocket 规则文件
│   └── shadowrocket.conf
└── surge/             # Surge 配置
    └── rules/         # Surge 规则文件
```

## 规则格式

- `DOMAIN-SUFFIX,example.com` - 匹配域名后缀
- `IP-CIDR,x.x.x.x/xx` - 匹配 IP 地址段
- `PROCESS-NAME,AppName` - 匹配进程名称

## 开发指南

- 按类别整理规则
- 为不明显的规则添加注释
- 修改规则列表时更新日期注释
- 部署前测试规则

## 部署

运行 `./deploy.sh` 提交并推送更改到仓库。

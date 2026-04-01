# BoxX 封锁列表功能设计

## 概述

为 BoxX 添加域名/IP 封锁功能，通过 sing-box 的 route rules 实现网络层拦截（action: reject）。支持主窗口统一管理和监控窗口快速封锁两个入口。

## 数据存储

### 文件

`~/Library/Application Support/BoxX/rules/block-custom.json`

### 格式

与 sing-box rule set 标准格式一致：

```json
{
  "version": 2,
  "rules": [
    { "domain_suffix": ["sfrclak.com", "malware.cn"] },
    { "domain": ["evil.example.com"] },
    { "ip_cidr": ["142.11.206.73/32"] }
  ]
}
```

### 读写

新增 `BlockListManager` 负责读写 block-custom.json：
- `load() -> [BlockEntry]`：读取并解析为扁平列表
- `add(entries: [BlockEntry])`：追加条目，按类型合并到对应 rule 对象
- `remove(entry: BlockEntry)`：删除单条
- `removeAll()`：清空

`BlockEntry` 结构：
```swift
struct BlockEntry: Identifiable, Hashable {
    let id: UUID
    let type: BlockEntryType  // .domainSuffix, .domain, .ipCIDR
    let value: String         // "sfrclak.com" 或 "142.11.206.73/32"
}
```

## ConfigEngine 自动注入

在 `buildRuntimeConfig()` 中：

1. 检查 `rules/block-custom.json` 是否存在且非空
2. 在 `route.rule_set` 数组中注入：
   ```json
   {
     "type": "local",
     "tag": "block-custom",
     "format": "source",
     "path": "{baseDir}/rules/block-custom.json"
   }
   ```
3. 在 `route.rules` 数组的系统规则（dns-hijack、sniff）之后、用户规则之前注入：
   ```json
   { "rule_set": ["block-custom"], "action": "reject" }
   ```

如果 block-custom.json 不存在或为空，不注入，避免 sing-box 报错。

## UI：主窗口封锁列表页

### 侧栏入口

在"规则"分组中添加"封锁列表"，图标 `nosign`，位于"规则测试"之后。

### 页面布局

```
┌─────────────────────────────────────────────┐
│ [+ 添加]  [搜索...]           N 条封锁规则  │
├─────────────────────────────────────────────┤
│ 类型        值                    操作       │
│ DOMAIN-SUF  sfrclak.com          [删除]     │
│ IP-CIDR     142.11.206.73/32     [删除]     │
│ DOMAIN-SUF  malware.cn           [删除]     │
│ ...                                         │
└─────────────────────────────────────────────┘
```

### 添加 Sheet

- 文本框输入域名或 IP（支持批量粘贴，一行一个）
- 自动识别类型：
  - 包含 `/` → IP-CIDR（如不含 `/`，IP 地址自动补 `/32`）
  - 其他 → DOMAIN-SUFFIX
- 确认后写入 block-custom.json，触发 `pendingReload = true`

### 删除

- 单行删除按钮
- 右键菜单"删除"
- 触发 `pendingReload = true`

## UI：监控窗口快速封锁

### 右键菜单

在 ConnectionsView 的右键菜单中，"添加规则"下方添加"封锁域名"选项。

点击后：
1. 提取连接的 `domainForRule`（和现有 AddRuleSheet 取值一致）
2. 调用 `BlockListManager.add()` 写入 block-custom.json
3. 设置 `pendingReload = true`
4. 可选：显示简短确认提示

## 生效机制

1. 用户添加/删除封锁条目 → 写入 block-custom.json
2. 设置 `appState.pendingReload = true`
3. 主窗口显示黄色横幅"配置已更新，点击应用后生效"
4. 用户点击"应用配置" → `deployRuntime()` + 热重载
5. ConfigEngine 在构建 runtime-config.json 时自动注入 block-custom 规则

## 文件变更清单

| 文件 | 变更 |
|------|------|
| `BlockListManager.swift` | 新增：读写 block-custom.json |
| `BlockEntry.swift` | 新增：数据模型 |
| `BlockListView.swift` | 新增：主窗口封锁列表页面 |
| `AddBlockSheet.swift` | 新增：添加封锁条目 Sheet |
| `ConfigEngine.swift` | 修改：buildRuntimeConfig 注入 block rule_set + reject 规则 |
| `MainView.swift` | 修改：侧栏添加封锁列表入口 |
| `ConnectionsView.swift` | 修改：右键菜单添加"封锁域名" |
| `Localizable.strings (en)` | 修改：添加封锁相关文案 |
| `Localizable.strings (zh)` | 修改：添加封锁相关文案 |

## 不做的事

- 不做远程封锁订阅列表（未来可扩展）
- 不做定时自动更新
- 不做按进程封锁
- 不做 DNS 层封锁（只做路由层 reject）

# 规则集增强设计

## 概述

增强 BoxX 的规则集管理功能，支持新增、完整编辑、自动更新间隔配置。

## 当前状态

- `RuleSetsView.swift` 显示规则集列表，支持编辑出站策略、删除、手动更新
- `RuleSetEditSheet` 仅能修改出站策略
- 规则集存储在 `config.json` 的 `route.rule_set` 数组中，每个条目是 JSONValue
- sing-box 支持 `update_interval` 字段实现自动更新，但当前未使用

## 设计

### 1. 新增规则集

**入口**：规则集页面顶部工具栏增加"新增"按钮。

**UI**：Sheet 弹窗，表单字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| 类型 | Picker (remote/local) | 切换时动态显示/隐藏相关字段 |
| 标签 (tag) | TextField | 唯一标识，不可与现有标签重复 |
| URL | TextField | 仅 remote，远程规则集地址 |
| 路径 (path) | TextField | 仅 local，本地文件路径 |
| 格式 (format) | Picker (source/binary) | 规则集文件格式 |
| 出站策略 | Picker | 可用 outbounds + REJECT |
| download_detour | Picker | 仅 remote，下载时使用的出站 |
| 更新间隔 (小时) | TextField (数字) | 仅 remote，可留空使用全局默认 |

**保存逻辑**：
1. 验证标签不为空且不重复
2. 构建 JSONValue 对象，写入 `route.rule_set`
3. 在 `route.rules` 中创建对应路由规则（引用该标签 + 设置出站）
4. 调用 `configEngine.save(restartRequired: true)`

### 2. 编辑规则集

**UI**：复用新增弹窗组件（`RuleSetFormSheet`），预填现有值。

**限制**：标签字段只读（灰色显示）。

**保存逻辑**：
1. 在 `route.rule_set` 中找到对应标签的条目，更新字段
2. 同步更新 `route.rules` 中的出站策略
3. 调用 `configEngine.save(restartRequired: true)`

### 3. 删除规则集（级联清理）

当前 `deleteRuleSet()` 已实现级联删除：从 `route.rule_set` 移除条目，同时从 `route.rules` 中移除所有仅引用该标签的规则。

当前实现检查 `tags == [tag]`（仅当规则只引用这一个标签时才删除）。需要增强：如果一条规则引用了多个标签，只移除该标签而不删除整条规则。

### 4. 全局默认更新间隔

**入口**：`SettingsView` → `GeneralSettingsTab`，新增 Section。

**实现**：
- 使用 `@AppStorage("ruleSetUpdateInterval")` 存储，默认值 24（小时）
- UI：Picker 或 TextField，常用选项：6h、12h、24h、48h、72h

### 5. update_interval 自动补全

**在 `ConfigEngine.buildRuntimeConfig()` 中**：遍历 `runtime.route.ruleSet`，对 type=remote 的条目：
- 如果没有 `update_interval` 字段，用全局默认值补上
- 格式：`"24h0m0s"`（sing-box 的 Duration 格式）

**不修改** `config.json` 中的原始数据，只在 runtime 构建时补全。

### 6. 文件变更清单

| 文件 | 变更 |
|------|------|
| `Views/RuleSetsView.swift` | 新增按钮、替换 RuleSetEditSheet 为 RuleSetFormSheet、增强删除逻辑 |
| `Views/SettingsView.swift` | GeneralSettingsTab 新增规则集更新间隔配置 |
| `Services/ConfigEngine.swift` | buildRuntimeConfig() 中补全 update_interval |

### 7. RuleSetFormSheet 设计

统一的新增/编辑表单组件：

```swift
struct RuleSetFormSheet: View {
    enum Mode { case add, edit(JSONValue) }
    let mode: Mode
    let availableOutbounds: [String]
    let existingTags: Set<String>
    let onSave: (JSONValue, String) -> Void  // (ruleSetDef, outbound)
    let onCancel: () -> Void

    // Form state
    @State var ruleSetType: String = "remote"
    @State var tag: String = ""
    @State var url: String = ""
    @State var path: String = ""
    @State var format: String = "binary"
    @State var outbound: String = "Proxy"
    @State var downloadDetour: String = "DIRECT"
    @State var updateIntervalHours: String = ""  // 空 = 用全局默认
}
```

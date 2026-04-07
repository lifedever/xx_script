# ShadowProxy 批次 2：macOS App + UI + 订阅 + 测速 设计规格

> 日期：2026-04-07
> 状态：设计确认
> 前置：批次 1 完成（传输层 + VLESS/Trojan/VMess padding/DoH）

## 背景

批次 1 完成了代理引擎的生产级能力。批次 2 将现有基础 SwiftUI App 改造为菜单栏常驻 + 独立主窗口的完整 macOS App，并新增订阅管理、节点测速、请求查看器等功能。

## 目标

- 菜单栏常驻，Popover 快速操作（开关/节点/分流）
- 侧边栏导航主窗口（概览/策略组/节点/测速/日志/订阅/设置）
- 请求查看器独立窗口，实时表格流
- 订阅 URL 自动拉取解析（Base64/SIP008/Clash YAML）
- 节点延迟测速
- 开机自启（SMAppService）

---

## 1. App 架构

### 1.1 App 形态

菜单栏常驻 + 独立主窗口（Surge 风格）。

- `LSUIElement = true`：不显示在 Dock
- `NSStatusItem`：菜单栏图标常驻
- `NSPopover`：点击图标弹出快速操作面板
- 主窗口通过 Popover 底部"仪表盘"按钮打开
- 关闭主窗口后菜单栏继续工作

### 1.2 文件结构

```
ShadowProxyApp/
├── ShadowProxyApp.swift          # @main，Scene 定义（主窗口 + 请求查看器窗口）
├── AppDelegate.swift             # NSStatusItem + NSPopover + 信号清理
├── MenuBarPopover.swift          # 菜单栏弹出面板
├── MainWindow/
│   ├── MainWindowView.swift      # NavigationSplitView 侧边栏 + detail
│   ├── OverviewView.swift        # 概览页
│   ├── ProxyGroupsView.swift     # 策略组页
│   ├── NodeListView.swift        # 节点列表页
│   ├── SpeedTestView.swift       # 测速页
│   ├── LogView.swift             # 日志页
│   ├── SubscriptionView.swift    # 订阅管理页
│   └── SettingsView.swift        # 设置页
├── RequestViewer/
│   └── RequestViewerWindow.swift # 请求查看器独立窗口
├── ProxyViewModel.swift          # 共享状态（Popover + MainWindow + 请求查看器）
└── SubscriptionManager.swift     # 订阅拉取/解析/存储
```

### 1.3 状态管理

`ProxyViewModel` 是 `@MainActor` 单例，AppDelegate、Popover、MainWindow、RequestViewer 共享同一实例。

---

## 2. 菜单栏 Popover 面板

### 2.1 布局（从上到下）

1. **顶栏**：状态灯（绿/灰）+ "ShadowProxy" + Toggle 开关
2. **模式栏**：系统代理（选中）/ TUN（灰显，Phase 3）
3. **当前节点**：Proxy 组当前选中节点名 + 延迟 ms
4. **分流摘要**：列出服务分流组及当前节点，最多 5 条，超出显示"更多..."
5. **底栏**：仪表盘（打开主窗口）| 重载 | 退出

### 2.2 实现

- `NSStatusItem` 在 AppDelegate 中创建
- 图标：SF Symbol `shield.checkered`，运行时绿色，停止时灰色
- `NSPopover` 嵌 `NSHostingView<MenuBarPopover>`
- `popover.behavior = .transient`（点外部自动关闭）
- 固定宽度 280pt，高度自适应

### 2.3 交互

- Toggle ON → `viewModel.start()`
- Toggle OFF → `viewModel.stop()`
- "仪表盘" → `openWindow(id: "main")`
- "重载" → `viewModel.reload()`
- "退出" → `NSApp.terminate(nil)`

---

## 3. 主窗口

### 3.1 布局

`NavigationSplitView` 两栏：左侧 sidebar + 右侧 detail。

侧边栏用 `List(selection:)` 绑定 `SidebarItem` enum：

```swift
enum SidebarItem: String, CaseIterable {
    case overview = "概览"
    case proxyGroups = "策略组"
    case nodes = "节点列表"
    case speedTest = "测速"
    case log = "日志"
    case subscription = "订阅"
    case settings = "设置"
}
```

窗口最小尺寸 700x500。窗口 ID `"main"`，通过 `openWindow(id:)` 打开。

### 3.2 各页面

**概览页**：状态卡片（运行状态/当前节点/延迟/活跃连接）+ 服务分流摘要表格。

**策略组页**：所有 ProxyGroup 列表，每组展开可选择节点（Picker）。

**节点列表页**：全部节点平铺显示协议/服务器/延迟，支持搜索过滤。手动节点和订阅节点混合展示，订阅节点带前缀标识。

**测速页**：见第 5 节。

**日志页**：实时日志流（复用 splog.onLog），LazyVStack + ScrollView 自动滚动。搜索框过滤，日志级别 Picker 过滤。

**订阅页**：见第 6 节。

**设置页**：见第 7 节。

---

## 4. 请求查看器

### 4.1 独立窗口

窗口 ID `"request-viewer"`，通过主窗口或 Popover 打开。表格流风格（Surge 监控页）。

### 4.2 数据模型

```swift
struct RequestRecord: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let host: String
    let port: UInt16
    let requestProtocol: String    // "HTTPS" / "HTTP" / "SOCKS5"
    let policy: String             // "🤖OpenAI" / "DIRECT" / "Proxy"
    let node: String?              // 实际节点名
    let matchedRule: String?       // "DOMAIN-SUFFIX,anthropic.com"
    var elapsed: Int?              // ms，连接完成后回填
    var status: RequestStatus      // .active / .completed / .failed
}

enum RequestStatus: Sendable {
    case active, completed, failed
}
```

### 4.3 数据流

- `ProxyEngine.handleRequest()` 每次处理请求时生成 `RequestRecord`
- 通过回调发布到 `ProxyViewModel.requestRecords`
- 环形缓冲区，最多 2000 条，超出丢弃最旧

### 4.4 UI 功能

- **工具栏**：筛选按钮（全部/代理/直连/拒绝）+ 搜索框 + 暂停/继续 + 清除
- **表格列**：时间 | 协议 | 域名 | 策略 | 耗时
- **底部状态栏**：请求总数 / 代理数 / 直连数
- 自动滚动到最新（暂停时停止滚动但继续记录）
- 颜色编码：代理请求正常色，直连灰色，失败红色

---

## 5. 节点测速

### 5.1 测速逻辑

对每个节点建立代理连接，通过代理请求 `http://www.gstatic.com/generate_204`，测量从建连到收到 204 响应的总耗时（TCP + TLS + 代理握手 + HTTP）。

- 超时 5 秒标记为失败
- 结果存 `ProxyViewModel.nodeSpeeds: [String: Int]`（节点名 → ms）
- 支持"测全部"和"测选中"两种模式
- 并发测速，每组最多 8 个并行

### 5.2 UI

测速页显示所有节点列表，每行：节点名 | 协议 | 延迟（未测/-/ms）。

顶部按钮："测全部" / "测选中"。测速进行中显示进度。

延迟颜色：<100ms 绿，100-300ms 黄，>300ms 红，失败灰。

---

## 6. 订阅管理

### 6.1 支持格式

| 格式 | 识别方式 | 说明 |
|------|---------|------|
| Base64 | 解码后每行一个 URI | `ss://...`、`vmess://...`（base64 JSON） |
| SIP008 | JSON，有 `servers` 数组 | Shadowsocks 标准订阅格式 |
| Clash YAML | 有 `proxies:` key | Clash 配置片段 |

### 6.2 数据存储

```
~/.shadowproxy/subscriptions/
├── subscriptions.json          # 订阅元信息
└── nodes/
    ├── socloud.json            # 解析后的节点列表
    └── bajie.json
```

`subscriptions.json` 格式：
```json
[
  {
    "id": "uuid",
    "name": "SoCloud",
    "url": "https://...",
    "lastUpdate": "2026-04-07T10:00:00Z",
    "nodeCount": 18,
    "autoRefreshHours": 24
  }
]
```

### 6.3 SubscriptionManager

```swift
final class SubscriptionManager {
    func add(name: String, url: String) async throws
    func refresh(id: String) async throws
    func refreshAll() async throws
    func delete(id: String) throws
    func allNodes() -> [String: ServerConfig]    // 合并全部订阅节点
    func subscriptions() -> [SubscriptionInfo]   // 元信息列表
}
```

节点名带订阅前缀：`[SoCloud] 🇯🇵 日本 01`。

### 6.4 与 ProxyEngine 集成

- `ProxyEngine.init()` 时 `SubscriptionManager.allNodes()` 合并到 `config.proxies`
- 策略组 members 可引用订阅节点名
- 刷新订阅后 `engine.reload()` 生效

### 6.5 URI 解析

**ss:// URI**：`ss://base64(method:password)@server:port#name` 或 SIP002 格式。

**vmess:// URI**：`vmess://base64(json)`，JSON 包含 `add`/`port`/`id`/`aid`/`net`/`tls` 等字段。

**vless:// URI**：`vless://uuid@server:port?type=tcp&security=tls&sni=xxx#name`

**trojan:// URI**：`trojan://password@server:port?sni=xxx#name`

---

## 7. 设置 + 开机自启

### 7.1 设置项

| 设置 | 类型 | 默认值 |
|------|------|--------|
| 监听端口 | UInt16 | 7891 |
| DNS 服务器 | String | https://223.5.5.5/dns-query |
| 日志级别 | Picker | info |
| 开机自启 | Toggle | false |
| 订阅自动刷新 | Toggle | true |

### 7.2 持久化

`UserDefaults`，修改端口/DNS 等后提示"需要重启代理"。

### 7.3 开机自启

macOS 13+ `SMAppService.mainApp.register()` / `unregister()`。

---

## 文件变更清单

### 新增文件

| 文件 | 说明 |
|------|------|
| `ShadowProxyApp/AppDelegate.swift` | 重写：NSStatusItem + NSPopover + 信号清理 |
| `ShadowProxyApp/MenuBarPopover.swift` | 菜单栏弹出面板 |
| `ShadowProxyApp/MainWindow/MainWindowView.swift` | 主窗口 NavigationSplitView |
| `ShadowProxyApp/MainWindow/OverviewView.swift` | 概览页 |
| `ShadowProxyApp/MainWindow/ProxyGroupsView.swift` | 策略组页 |
| `ShadowProxyApp/MainWindow/NodeListView.swift` | 节点列表页 |
| `ShadowProxyApp/MainWindow/SpeedTestView.swift` | 测速页 |
| `ShadowProxyApp/MainWindow/LogView.swift` | 日志页 |
| `ShadowProxyApp/MainWindow/SubscriptionView.swift` | 订阅管理页 |
| `ShadowProxyApp/MainWindow/SettingsView.swift` | 设置页 |
| `ShadowProxyApp/RequestViewer/RequestViewerWindow.swift` | 请求查看器 |
| `ShadowProxyApp/SubscriptionManager.swift` | 订阅拉取/解析/存储 |

### 修改文件

| 文件 | 改动 |
|------|------|
| `ShadowProxyApp/ShadowProxyApp.swift` | 改为 LSUIElement，多窗口 Scene |
| `ShadowProxyApp/ProxyViewModel.swift` | 新增 requestRecords、nodeSpeeds、订阅集成 |
| `ShadowProxyApp/ContentView.swift` | 删除或重构为 MainWindowView |
| `Sources/ShadowProxyCore/Engine/ProxyEngine.swift` | handleRequest 生成 RequestRecord 回调 |
| `project.yml` | 新增 MainWindow/ 和 RequestViewer/ source paths，ServiceManagement framework |

### 不变的文件

引擎层（Inbound/Outbound/Relay/Router/Protocol/*）不变。

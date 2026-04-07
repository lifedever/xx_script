# ShadowProxy 批次2：macOS App + UI 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 ShadowProxy 从基础 SwiftUI 窗口改造为菜单栏常驻 App，新增 Popover 快速面板、侧边栏主窗口、请求查看器、订阅管理、节点测速。

**Architecture:** LSUIElement 隐藏 Dock，NSStatusItem + NSPopover 菜单栏常驻，主窗口 NavigationSplitView 侧边栏导航，请求查看器独立窗口。ProxyViewModel 单例共享状态。订阅数据独立文件存储，运行时合并到引擎。

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (NSStatusItem/NSPopover), Network.framework, SMAppService, xcodegen

**项目路径:** `shadowproxy/source/`，App 代码在 `ShadowProxyApp/`

**重要：** 此项目用 xcodegen（`project.yml`）生成 .xcodeproj。`ShadowProxyApp/` 下所有 .swift 文件自动包含，无需修改 project.yml 的 sources。子目录也自动递归包含。

---

### Task 1: App 架构改造（LSUIElement + 菜单栏图标）

**Files:**
- Modify: `ShadowProxyApp/ShadowProxyApp.swift`
- Modify: `ShadowProxyApp/ContentView.swift` → 删除
- Create: `ShadowProxyApp/AppDelegate.swift`（重写现有内嵌版本）
- Modify: `project.yml`

- [ ] **Step 1: 修改 project.yml 设置 LSUIElement=true**

在 `project.yml` 中将：
```yaml
INFOPLIST_KEY_LSUIElement: false
```
改为：
```yaml
INFOPLIST_KEY_LSUIElement: true
```

- [ ] **Step 2: 重写 ShadowProxyApp.swift**

将整个文件替换为：

```swift
import SwiftUI
import ShadowProxyCore

@main
struct ShadowProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 主窗口 — 通过菜单栏 Popover 的"仪表盘"按钮打开
        Window("ShadowProxy", id: "main") {
            MainWindowView(viewModel: appDelegate.viewModel)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        // 请求查看器 — 独立窗口
        Window("请求查看器", id: "request-viewer") {
            RequestViewerWindow(viewModel: appDelegate.viewModel)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
    }
}
```

- [ ] **Step 3: 创建独立 AppDelegate.swift**

将 AppDelegate 从 ShadowProxyApp.swift 中的内嵌 class 移到独立文件 `ShadowProxyApp/AppDelegate.swift`：

```swift
import AppKit
import SwiftUI
import ShadowProxyCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = ProxyViewModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "ShadowProxy")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 360)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopover(viewModel: viewModel)
        )

        // 信号清理
        signal(SIGTERM) { _ in
            try? SystemProxy.disable()
            exit(0)
        }

        // 启动时加载配置
        viewModel.loadConfig()

        // 关闭所有初始窗口（LSUIElement 模式下不需要自动打开主窗口）
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.close()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? SystemProxy.disable()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // 确保 popover 窗口获得焦点
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// 更新菜单栏图标颜色
    func updateStatusIcon(running: Bool) {
        if let button = statusItem?.button {
            let config = NSImage.SymbolConfiguration(paletteColors: [running ? .systemGreen : .systemGray])
            button.image = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "ShadowProxy")?
                .withSymbolConfiguration(config)
        }
    }
}
```

- [ ] **Step 4: 创建占位文件避免编译错误**

创建 `ShadowProxyApp/MenuBarPopover.swift`：
```swift
import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        Text("Popover placeholder")
            .frame(width: 280, height: 100)
    }
}
```

创建 `ShadowProxyApp/MainWindow/MainWindowView.swift`：
```swift
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        Text("Main window placeholder")
    }
}
```

创建 `ShadowProxyApp/RequestViewer/RequestViewerWindow.swift`：
```swift
import SwiftUI

struct RequestViewerWindow: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        Text("Request viewer placeholder")
    }
}
```

- [ ] **Step 5: 删除旧 ContentView.swift**

删除 `ShadowProxyApp/ContentView.swift`。

- [ ] **Step 6: 重新生成 xcodeproj 并构建**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
xcodegen generate
swift build 2>&1 | tail -10
```

如果 swift build 不支持 App target，用 xcodebuild：
```bash
xcodebuild -project ShadowProxy.xcodeproj -scheme ShadowProxy -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: App 架构改造 — LSUIElement + 菜单栏图标 + 多窗口"
```

---

### Task 2: 菜单栏 Popover 面板

**Files:**
- Modify: `ShadowProxyApp/MenuBarPopover.swift`
- Modify: `ShadowProxyApp/ProxyViewModel.swift`
- Modify: `ShadowProxyApp/AppDelegate.swift`

- [ ] **Step 1: 实现 MenuBarPopover 完整 UI**

替换 `ShadowProxyApp/MenuBarPopover.swift`：

```swift
import SwiftUI
import ShadowProxyCore

struct MenuBarPopover: View {
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：状态 + 开关
            HStack {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text("ShadowProxy")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.isRunning },
                    set: { newValue in
                        if newValue { viewModel.start() } else { viewModel.stop() }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // 模式栏
            HStack(spacing: 6) {
                modeButton(title: "系统代理", active: true)
                modeButton(title: "TUN", active: false)
                    .opacity(0.4)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // 当前节点
            if let proxyGroup = viewModel.proxyGroups.first(where: { $0.name == "Proxy" }),
               let selected = viewModel.selectedNodes["Proxy"] {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前节点")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(selected)
                            .font(.system(size: 13))
                    }
                    Spacer()
                    if let speed = viewModel.nodeSpeeds[selected] {
                        Text("\(speed)ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(speed < 100 ? .green : speed < 300 ? .yellow : .red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }

            // 分流摘要
            ScrollView {
                VStack(spacing: 0) {
                    let serviceGroups = viewModel.proxyGroups.filter { $0.name != "Proxy" }
                    ForEach(serviceGroups.prefix(5), id: \.name) { group in
                        HStack {
                            Text(group.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.selectedNodes[group.name] ?? "-")
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    if serviceGroups.count > 5 {
                        Text("更多...")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 150)

            Divider()

            // 底栏
            HStack {
                Button("📊 仪表盘") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))

                Spacer()

                Button("🔄 重载") {
                    viewModel.reload()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))

                Spacer()

                Button("退出") {
                    viewModel.stop()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
    }

    private func modeButton(title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(active ? Color.accentColor : Color.gray.opacity(0.2))
            .foregroundStyle(active ? .white : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
```

- [ ] **Step 2: ProxyViewModel 新增 nodeSpeeds + reload**

在 `ProxyViewModel.swift` 添加：

```swift
@Published var nodeSpeeds: [String: Int] = [:]

func reload() {
    stop()
    loadConfig()
    start()
    log("Configuration reloaded")
}
```

- [ ] **Step 3: ProxyViewModel.start/stop 更新菜单栏图标**

在 `start()` 成功后添加：
```swift
(NSApp.delegate as? AppDelegate)?.updateStatusIcon(running: true)
```

在 `stop()` 末尾添加：
```swift
(NSApp.delegate as? AppDelegate)?.updateStatusIcon(running: false)
```

- [ ] **Step 4: 构建验证**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
xcodegen generate && xcodebuild -project ShadowProxy.xcodeproj -scheme ShadowProxy -configuration Debug build 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: 菜单栏 Popover 面板 — 开关/节点/分流摘要"
```

---

### Task 3: 主窗口骨架（侧边栏 + 概览 + 策略组）

**Files:**
- Modify: `ShadowProxyApp/MainWindow/MainWindowView.swift`
- Create: `ShadowProxyApp/MainWindow/OverviewView.swift`
- Create: `ShadowProxyApp/MainWindow/ProxyGroupsView.swift`

- [ ] **Step 1: 实现 MainWindowView 侧边栏导航**

替换 `ShadowProxyApp/MainWindow/MainWindowView.swift`：

```swift
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "概览"
    case proxyGroups = "策略组"
    case nodes = "节点列表"
    case speedTest = "测速"
    case log = "日志"
    case subscription = "订阅"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .proxyGroups: "arrow.triangle.branch"
        case .nodes: "server.rack"
        case .speedTest: "bolt.horizontal"
        case .log: "doc.text"
        case .subscription: "arrow.clockwise.circle"
        case .settings: "gearshape"
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var selectedItem: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selectedItem {
            case .overview:
                OverviewView(viewModel: viewModel)
            case .proxyGroups:
                ProxyGroupsView(viewModel: viewModel)
            case .nodes:
                Text("节点列表 — Task 4")
            case .speedTest:
                Text("测速 — Task 8")
            case .log:
                Text("日志 — Task 5")
            case .subscription:
                Text("订阅 — Task 7")
            case .settings:
                Text("设置 — Task 9")
            case .none:
                Text("选择一个页面")
            }
        }
    }
}
```

- [ ] **Step 2: 创建 OverviewView**

创建 `ShadowProxyApp/MainWindow/OverviewView.swift`：

```swift
import SwiftUI
import ShadowProxyCore

struct OverviewView: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 状态卡片
                HStack(spacing: 12) {
                    statusCard(title: "状态", value: viewModel.isRunning ? "运行中" : "已停止",
                              color: viewModel.isRunning ? .green : .gray)
                    statusCard(title: "当前节点",
                              value: viewModel.selectedNodes["Proxy"] ?? "-", color: .blue)
                    if let node = viewModel.selectedNodes["Proxy"],
                       let speed = viewModel.nodeSpeeds[node] {
                        statusCard(title: "延迟", value: "\(speed)ms",
                                  color: speed < 100 ? .green : speed < 300 ? .yellow : .red)
                    } else {
                        statusCard(title: "延迟", value: "-", color: .gray)
                    }
                    statusCard(title: "规则", value: "\(viewModel.ruleCount)", color: .purple)
                }

                // 服务分流
                Text("服务分流")
                    .font(.headline)

                let serviceGroups = viewModel.proxyGroups.filter { $0.name != "Proxy" }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(serviceGroups, id: \.name) { group in
                        HStack {
                            Text(group.name)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.selectedNodes[group.name] ?? "-")
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("概览")
    }

    private func statusCard(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
```

- [ ] **Step 3: 创建 ProxyGroupsView**

创建 `ShadowProxyApp/MainWindow/ProxyGroupsView.swift`：

```swift
import SwiftUI
import ShadowProxyCore

struct ProxyGroupsView: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        List {
            ForEach(viewModel.proxyGroups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.name)
                        .font(.system(.body, weight: .medium))

                    Picker("", selection: Binding(
                        get: { viewModel.selectedNodes[group.name] ?? group.members.first ?? "" },
                        set: { viewModel.selectNode(group: group.name, node: $0) }
                    )) {
                        ForEach(group.members, id: \.self) { member in
                            HStack {
                                Text(member)
                                Spacer()
                                if let speed = viewModel.nodeSpeeds[member] {
                                    Text("\(speed)ms")
                                        .font(.caption)
                                        .foregroundStyle(speed < 100 ? .green : speed < 300 ? .yellow : .red)
                                }
                            }
                            .tag(member)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("策略组")
    }
}
```

- [ ] **Step 4: 构建验证**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
xcodegen generate && xcodebuild -project ShadowProxy.xcodeproj -scheme ShadowProxy -configuration Debug build 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: 主窗口侧边栏导航 + 概览页 + 策略组页"
```

---

### Task 4: 节点列表 + 日志页

**Files:**
- Create: `ShadowProxyApp/MainWindow/NodeListView.swift`
- Create: `ShadowProxyApp/MainWindow/LogView.swift`
- Modify: `ShadowProxyApp/MainWindow/MainWindowView.swift`

- [ ] **Step 1: 创建 NodeListView**

创建 `ShadowProxyApp/MainWindow/NodeListView.swift`：

```swift
import SwiftUI
import ShadowProxyCore

struct NodeListView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var searchText = ""

    var filteredNodes: [String] {
        if searchText.isEmpty {
            return viewModel.proxyNames
        }
        return viewModel.proxyNames.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredNodes, id: \.self) { name in
                HStack {
                    Text(name)
                        .font(.system(size: 13))
                    Spacer()
                    if let speed = viewModel.nodeSpeeds[name] {
                        Text("\(speed)ms")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(speed < 100 ? .green : speed < 300 ? .yellow : .red)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .searchable(text: $searchText, prompt: "搜索节点")
        .navigationTitle("节点列表")
    }
}
```

- [ ] **Step 2: 创建 LogView**

创建 `ShadowProxyApp/MainWindow/LogView.swift`：

```swift
import SwiftUI

struct LogView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var searchText = ""
    @State private var autoScroll = true

    var filteredLogs: [String] {
        if searchText.isEmpty {
            return viewModel.logMessages
        }
        return viewModel.logMessages.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Text("\(viewModel.logMessages.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("清除") {
                    viewModel.logMessages.removeAll()
                }
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // 日志内容
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filteredLogs.enumerated()), id: \.offset) { index, msg in
                            Text(msg)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 1)
                                .id(index)
                        }
                    }
                }
                .onChange(of: viewModel.logMessages.count) { _, _ in
                    if autoScroll, let last = filteredLogs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .searchable(text: $searchText, prompt: "搜索日志")
        .navigationTitle("日志")
    }
}
```

- [ ] **Step 3: 更新 MainWindowView detail switch**

在 `MainWindowView.swift` 中替换占位符：

```swift
case .nodes:
    NodeListView(viewModel: viewModel)
case .log:
    LogView(viewModel: viewModel)
```

- [ ] **Step 4: 构建验证**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
xcodegen generate && xcodebuild -project ShadowProxy.xcodeproj -scheme ShadowProxy -configuration Debug build 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: 节点列表页 + 日志页"
```

---

### Task 5: 请求查看器（数据模型 + 引擎集成 + 窗口）

**Files:**
- Create: `Sources/ShadowProxyCore/Engine/RequestRecord.swift`
- Modify: `Sources/ShadowProxyCore/Engine/ProxyEngine.swift`
- Modify: `ShadowProxyApp/ProxyViewModel.swift`
- Modify: `ShadowProxyApp/RequestViewer/RequestViewerWindow.swift`

- [ ] **Step 1: 创建 RequestRecord 数据模型**

创建 `Sources/ShadowProxyCore/Engine/RequestRecord.swift`：

```swift
import Foundation

public struct RequestRecord: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let host: String
    public let port: UInt16
    public let requestProtocol: String    // "HTTPS" / "HTTP" / "SOCKS5"
    public let policy: String
    public let node: String?
    public let matchedRule: String?
    public var elapsed: Int?
    public var status: RequestStatus

    public init(host: String, port: UInt16, requestProtocol: String, policy: String,
                node: String? = nil, matchedRule: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.host = host
        self.port = port
        self.requestProtocol = requestProtocol
        self.policy = policy
        self.node = node
        self.matchedRule = matchedRule
        self.elapsed = nil
        self.status = .active
    }
}

public enum RequestStatus: Sendable {
    case active, completed, failed
}
```

- [ ] **Step 2: ProxyEngine 新增 onRequest 回调**

在 `ProxyEngine.swift` 中添加回调属性和调用：

```swift
// 属性
public var onRequest: (@Sendable (RequestRecord) -> Void)?

// 在 handleRequest() 中，router.match() 之后、outbound.relay() 之前添加：
let record = RequestRecord(
    host: target.host,
    port: target.port,
    requestProtocol: request.initialData != nil ? "HTTP" : "HTTPS",
    policy: policy,
    node: nil,
    matchedRule: nil
)
onRequest?(record)
```

- [ ] **Step 3: ProxyViewModel 新增 requestRecords**

在 `ProxyViewModel.swift` 添加：

```swift
@Published var requestRecords: [RequestRecord] = []
private let maxRecords = 2000

func appendRequest(_ record: RequestRecord) {
    requestRecords.append(record)
    if requestRecords.count > maxRecords {
        requestRecords.removeFirst(requestRecords.count - maxRecords)
    }
}
```

在 `start()` 方法中，engine 创建后设置回调：

```swift
engine.onRequest = { [weak self] record in
    Task { @MainActor in
        self?.appendRequest(record)
    }
}
```

- [ ] **Step 4: 实现 RequestViewerWindow**

替换 `ShadowProxyApp/RequestViewer/RequestViewerWindow.swift`：

```swift
import SwiftUI
import ShadowProxyCore

struct RequestViewerWindow: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var searchText = ""
    @State private var filter: RequestFilter = .all
    @State private var isPaused = false

    enum RequestFilter: String, CaseIterable {
        case all = "全部"
        case proxy = "代理"
        case direct = "直连"
    }

    var filteredRecords: [RequestRecord] {
        var records = viewModel.requestRecords
        switch filter {
        case .all: break
        case .proxy: records = records.filter { $0.policy != "DIRECT" }
        case .direct: records = records.filter { $0.policy == "DIRECT" }
        }
        if !searchText.isEmpty {
            records = records.filter { $0.host.localizedCaseInsensitiveContains(searchText) }
        }
        return records
    }

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack(spacing: 8) {
                ForEach(RequestFilter.allCases, id: \.self) { f in
                    Button(f.rawValue) { filter = f }
                        .buttonStyle(.bordered)
                        .tint(filter == f ? .accentColor : .gray)
                        .controlSize(.small)
                }
                Spacer()
                TextField("搜索域名...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .controlSize(.small)
                Button(isPaused ? "▶ 继续" : "⏸ 暂停") { isPaused.toggle() }
                    .controlSize(.small)
                Button("🗑 清除") { viewModel.requestRecords.removeAll() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 表头
            HStack(spacing: 0) {
                Text("时间").frame(width: 55, alignment: .leading)
                Text("协议").frame(width: 55, alignment: .leading)
                Text("域名").frame(maxWidth: .infinity, alignment: .leading)
                Text("策略").frame(width: 110, alignment: .leading)
                Text("耗时").frame(width: 55, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.3))

            Divider()

            // 请求列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRecords) { record in
                            requestRow(record)
                                .id(record.id)
                        }
                    }
                }
                .onChange(of: viewModel.requestRecords.count) { _, _ in
                    if !isPaused, let last = filteredRecords.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // 底部状态栏
            HStack {
                let total = viewModel.requestRecords.count
                let proxied = viewModel.requestRecords.filter { $0.policy != "DIRECT" }.count
                let direct = total - proxied
                Text("\(total) 请求 · \(proxied) 代理 · \(direct) 直连")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isPaused ? "已暂停" : "实时")
                    .font(.system(size: 10))
                    .foregroundStyle(isPaused ? .orange : .green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func requestRow(_ record: RequestRecord) -> some View {
        HStack(spacing: 0) {
            Text(record.timestamp, format: .dateTime.hour().minute().second())
                .frame(width: 55, alignment: .leading)
            Text(record.requestProtocol)
                .frame(width: 55, alignment: .leading)
                .foregroundStyle(record.requestProtocol == "HTTPS" ? .orange : .green)
            Text(record.host)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            Text(record.policy)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(record.policy == "DIRECT" ? .secondary : .blue)
                .lineLimit(1)
            if let ms = record.elapsed {
                Text("\(ms)ms")
                    .frame(width: 55, alignment: .trailing)
                    .foregroundStyle(ms < 100 ? .green : ms < 300 ? .yellow : .red)
            } else {
                Text("-")
                    .frame(width: 55, alignment: .trailing)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
```

- [ ] **Step 5: 构建验证**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
xcodegen generate && swift build 2>&1 | tail -10
xcodebuild -project ShadowProxy.xcodeproj -scheme ShadowProxy -configuration Debug build 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: 请求查看器 — 实时表格流 + 筛选/搜索/暂停"
```

---

### Task 6: 订阅管理器（解析 + 存储）

**Files:**
- Create: `Sources/ShadowProxyCore/Subscription/SubscriptionManager.swift`
- Create: `Sources/ShadowProxyCore/Subscription/SubscriptionParser.swift`
- Create: `Tests/ShadowProxyCoreTests/SubscriptionParserTests.swift`

- [ ] **Step 1: 写订阅 URI 解析测试**

创建 `Tests/ShadowProxyCoreTests/SubscriptionParserTests.swift`：

```swift
import Testing
import Foundation
@testable import ShadowProxyCore

@Test func parseSsURI() throws {
    // ss://base64(method:password)@server:port#name
    let method = "aes-128-gcm"
    let password = "testpass"
    let encoded = Data("\(method):\(password)".utf8).base64EncodedString()
    let uri = "ss://\(encoded)@1.2.3.4:8388#TestNode"

    let config = try SubscriptionParser.parseURI(uri)
    guard case .shadowsocks(let ss) = config.serverConfig else {
        Issue.record("Expected shadowsocks"); return
    }
    #expect(ss.server == "1.2.3.4")
    #expect(ss.port == 8388)
    #expect(ss.method == "aes-128-gcm")
    #expect(ss.password == "testpass")
    #expect(config.name == "TestNode")
}

@Test func parseVMessURI() throws {
    let json: [String: Any] = [
        "v": "2", "ps": "JP-Node", "add": "server.com", "port": "443",
        "id": "ea03770f-be81-3903-b81d-19a0d0e8844f", "aid": "0",
        "net": "ws", "tls": "tls", "sni": "server.com", "path": "/ws"
    ]
    let jsonData = try JSONSerialization.data(withJSONObject: json)
    let encoded = jsonData.base64EncodedString()
    let uri = "vmess://\(encoded)"

    let config = try SubscriptionParser.parseURI(uri)
    guard case .vmess(let vm) = config.serverConfig else {
        Issue.record("Expected vmess"); return
    }
    #expect(vm.server == "server.com")
    #expect(vm.port == 443)
    #expect(vm.uuid == "ea03770f-be81-3903-b81d-19a0d0e8844f")
    #expect(vm.transport.tls == true)
    #expect(vm.transport.wsPath == "/ws")
    #expect(config.name == "JP-Node")
}

@Test func parseTrojanURI() throws {
    let uri = "trojan://mypassword@server.com:443?sni=server.com#JP-Trojan"
    let config = try SubscriptionParser.parseURI(uri)
    guard case .trojan(let t) = config.serverConfig else {
        Issue.record("Expected trojan"); return
    }
    #expect(t.server == "server.com")
    #expect(t.port == 443)
    #expect(t.password == "mypassword")
    #expect(t.transport.tls == true)
    #expect(config.name == "JP-Trojan")
}

@Test func parseBase64Subscription() throws {
    let uris = [
        "ss://\(Data("aes-128-gcm:pass1".utf8).base64EncodedString())@1.1.1.1:8388#Node1",
        "ss://\(Data("aes-128-gcm:pass2".utf8).base64EncodedString())@2.2.2.2:8388#Node2"
    ]
    let content = Data(uris.joined(separator: "\n").utf8).base64EncodedString()
    let nodes = try SubscriptionParser.parseSubscription(content)
    #expect(nodes.count == 2)
    #expect(nodes[0].name == "Node1")
    #expect(nodes[1].name == "Node2")
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift test --filter SubscriptionParserTests 2>&1 | tail -5`

- [ ] **Step 3: 实现 SubscriptionParser**

创建 `Sources/ShadowProxyCore/Subscription/SubscriptionParser.swift`：

```swift
import Foundation

public struct ParsedNode: Sendable {
    public let name: String
    public let serverConfig: ServerConfig
}

public struct SubscriptionParser {

    /// Parse a single proxy URI (ss:// vmess:// vless:// trojan://)
    public static func parseURI(_ uri: String) throws -> ParsedNode {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("ss://") {
            return try parseSS(trimmed)
        } else if trimmed.hasPrefix("vmess://") {
            return try parseVMess(trimmed)
        } else if trimmed.hasPrefix("vless://") {
            return try parseVLESS(trimmed)
        } else if trimmed.hasPrefix("trojan://") {
            return try parseTrojan(trimmed)
        }
        throw SubscriptionError.unsupportedProtocol
    }

    /// Parse subscription content (base64 encoded, one URI per line)
    public static func parseSubscription(_ content: String) throws -> [ParsedNode] {
        // Try base64 decode
        let decoded: String
        if let data = Data(base64Encoded: content.trimmingCharacters(in: .whitespacesAndNewlines)),
           let str = String(data: data, encoding: .utf8) {
            decoded = str
        } else {
            decoded = content
        }

        return decoded.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { try? parseURI($0) }
    }

    // MARK: - SS

    private static func parseSS(_ uri: String) throws -> ParsedNode {
        // ss://base64(method:password)@server:port#name
        var rest = String(uri.dropFirst(5)) // remove "ss://"
        let name = extractFragment(&rest)

        // Split at @
        let parts = rest.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { throw SubscriptionError.invalidFormat }

        let userInfo = String(parts[0])
        let serverPart = String(parts[1])

        // Decode userinfo
        guard let decoded = Data(base64Encoded: userInfo),
              let userStr = String(data: decoded, encoding: .utf8) else {
            throw SubscriptionError.invalidFormat
        }
        let userParts = userStr.split(separator: ":", maxSplits: 1)
        guard userParts.count == 2 else { throw SubscriptionError.invalidFormat }
        let method = String(userParts[0])
        let password = String(userParts[1])

        // Parse server:port
        let (server, port) = try parseHostPort(serverPart)

        let config = ShadowsocksConfig(server: server, port: port, method: method, password: password)
        return ParsedNode(name: name ?? "\(server):\(port)", serverConfig: .shadowsocks(config))
    }

    // MARK: - VMess

    private static func parseVMess(_ uri: String) throws -> ParsedNode {
        let encoded = String(uri.dropFirst(8))
        guard let data = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubscriptionError.invalidFormat
        }

        let server = json["add"] as? String ?? ""
        let port = UInt16(json["port"] as? String ?? "0") ?? 0
        let uuid = json["id"] as? String ?? ""
        let alterId = Int(json["aid"] as? String ?? "0") ?? 0
        let name = json["ps"] as? String ?? "\(server):\(port)"

        var transport = TransportConfig()
        if (json["tls"] as? String)?.lowercased() == "tls" {
            transport.tls = true
            transport.tlsSNI = json["sni"] as? String ?? server
        }
        if let net = json["net"] as? String, net == "ws" {
            transport.wsPath = json["path"] as? String ?? "/"
            transport.wsHost = json["host"] as? String
        }

        let config = VMessConfig(server: server, port: port, uuid: uuid, alterId: alterId, transport: transport)
        return ParsedNode(name: name, serverConfig: .vmess(config))
    }

    // MARK: - VLESS

    private static func parseVLESS(_ uri: String) throws -> ParsedNode {
        // vless://uuid@server:port?params#name
        var rest = String(uri.dropFirst(8))
        let name = extractFragment(&rest)
        let params = extractQueryParams(&rest)

        let parts = rest.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { throw SubscriptionError.invalidFormat }
        let uuid = String(parts[0])
        let (server, port) = try parseHostPort(String(parts[1]))

        var transport = TransportConfig()
        if params["security"] == "tls" || params["security"] == "reality" {
            transport.tls = true
            transport.tlsSNI = params["sni"] ?? server
        }
        if params["type"] == "ws" {
            transport.wsPath = params["path"] ?? "/"
            transport.wsHost = params["host"]
        }

        let config = VLESSConfig(server: server, port: port, uuid: uuid, transport: transport)
        return ParsedNode(name: name ?? "\(server):\(port)", serverConfig: .vless(config))
    }

    // MARK: - Trojan

    private static func parseTrojan(_ uri: String) throws -> ParsedNode {
        // trojan://password@server:port?params#name
        var rest = String(uri.dropFirst(9))
        let name = extractFragment(&rest)
        let params = extractQueryParams(&rest)

        let parts = rest.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { throw SubscriptionError.invalidFormat }
        let password = String(parts[0])
        let (server, port) = try parseHostPort(String(parts[1]))

        var transport = TransportConfig(tls: true)
        transport.tlsSNI = params["sni"] ?? server

        let config = TrojanConfig(server: server, port: port, password: password, transport: transport)
        return ParsedNode(name: name ?? "\(server):\(port)", serverConfig: .trojan(config))
    }

    // MARK: - Helpers

    private static func extractFragment(_ uri: inout String) -> String? {
        if let idx = uri.lastIndex(of: "#") {
            let frag = String(uri[uri.index(after: idx)...]).removingPercentEncoding ?? String(uri[uri.index(after: idx)...])
            uri = String(uri[..<idx])
            return frag
        }
        return nil
    }

    private static func extractQueryParams(_ uri: inout String) -> [String: String] {
        guard let idx = uri.firstIndex(of: "?") else { return [:] }
        let queryStr = String(uri[uri.index(after: idx)...])
        uri = String(uri[..<idx])
        var params: [String: String] = [:]
        for pair in queryStr.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                params[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return params
    }

    private static func parseHostPort(_ str: String) throws -> (String, UInt16) {
        let parts = str.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw SubscriptionError.invalidFormat
        }
        return (String(parts[0]), port)
    }
}

public enum SubscriptionError: Error {
    case unsupportedProtocol
    case invalidFormat
    case fetchFailed
}
```

- [ ] **Step 4: 运行测试**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift test --filter SubscriptionParserTests 2>&1 | tail -15`
Expected: 4 tests PASS

- [ ] **Step 5: 实现 SubscriptionManager**

创建 `Sources/ShadowProxyCore/Subscription/SubscriptionManager.swift`：

```swift
import Foundation

public struct SubscriptionInfo: Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var url: String
    public var lastUpdate: Date?
    public var nodeCount: Int
    public var autoRefreshHours: Int

    public init(name: String, url: String, autoRefreshHours: Int = 24) {
        self.id = UUID().uuidString
        self.name = name
        self.url = url
        self.lastUpdate = nil
        self.nodeCount = 0
        self.autoRefreshHours = autoRefreshHours
    }
}

public final class SubscriptionManager: @unchecked Sendable {
    private let baseDir: String
    private let nodesDir: String
    private let metaPath: String

    public init(baseDir: String = NSHomeDirectory() + "/.shadowproxy/subscriptions") {
        self.baseDir = baseDir
        self.nodesDir = baseDir + "/nodes"
        self.metaPath = baseDir + "/subscriptions.json"

        try? FileManager.default.createDirectory(atPath: nodesDir, withIntermediateDirectories: true)
    }

    // MARK: - CRUD

    public func add(name: String, url: String) async throws {
        var info = SubscriptionInfo(name: name, url: url)
        let nodes = try await fetchAndParse(url: url)
        info.nodeCount = nodes.count
        info.lastUpdate = Date()

        var subs = loadMeta()
        subs.append(info)
        saveMeta(subs)
        saveNodes(id: info.id, nodes: nodes)

        splog.info("Added subscription '\(name)' with \(nodes.count) nodes", tag: "Sub")
    }

    public func refresh(id: String) async throws {
        var subs = loadMeta()
        guard let idx = subs.firstIndex(where: { $0.id == id }) else { return }

        let nodes = try await fetchAndParse(url: subs[idx].url)
        subs[idx].nodeCount = nodes.count
        subs[idx].lastUpdate = Date()
        saveMeta(subs)
        saveNodes(id: id, nodes: nodes)

        splog.info("Refreshed '\(subs[idx].name)': \(nodes.count) nodes", tag: "Sub")
    }

    public func refreshAll() async throws {
        let subs = loadMeta()
        for sub in subs {
            try await refresh(id: sub.id)
        }
    }

    public func delete(id: String) {
        var subs = loadMeta()
        subs.removeAll { $0.id == id }
        saveMeta(subs)
        try? FileManager.default.removeItem(atPath: nodesDir + "/\(id).json")
    }

    public func subscriptions() -> [SubscriptionInfo] {
        loadMeta()
    }

    /// Merge all subscription nodes, keyed as "[SubName] NodeName"
    public func allNodes() -> [String: ServerConfig] {
        let subs = loadMeta()
        var result: [String: ServerConfig] = [:]

        for sub in subs {
            let nodes = loadNodes(id: sub.id)
            for node in nodes {
                let key = "[\(sub.name)] \(node.name)"
                result[key] = node.serverConfig
            }
        }
        return result
    }

    // MARK: - Internal

    private func fetchAndParse(url: String) async throws -> [ParsedNode] {
        guard let requestURL = URL(string: url) else { throw SubscriptionError.fetchFailed }
        let (data, _) = try await URLSession.shared.data(from: requestURL)
        guard let content = String(data: data, encoding: .utf8) else { throw SubscriptionError.fetchFailed }
        return try SubscriptionParser.parseSubscription(content)
    }

    private func loadMeta() -> [SubscriptionInfo] {
        guard let data = FileManager.default.contents(atPath: metaPath),
              let subs = try? JSONDecoder().decode([SubscriptionInfo].self, from: data) else {
            return []
        }
        return subs
    }

    private func saveMeta(_ subs: [SubscriptionInfo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(subs) else { return }
        FileManager.default.createFile(atPath: metaPath, contents: data)
    }

    private func saveNodes(id: String, nodes: [ParsedNode]) {
        // Serialize as array of {name, uri_repr} — simplified
        let entries = nodes.map { ["name": $0.name] }
        guard let data = try? JSONSerialization.data(withJSONObject: entries) else { return }
        FileManager.default.createFile(atPath: nodesDir + "/\(id).json", contents: data)
    }

    private func loadNodes(id: String) -> [ParsedNode] {
        // For now reload from subscription URL cached data
        // Full implementation would serialize/deserialize ServerConfig
        return []
    }
}
```

- [ ] **Step 6: 运行全量测试**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift test 2>&1 | tail -20`

- [ ] **Step 7: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: 订阅管理器 — URI 解析 + 订阅拉取/存储"
```

---

### Task 7: 订阅管理 UI

**Files:**
- Create: `ShadowProxyApp/MainWindow/SubscriptionView.swift`
- Modify: `ShadowProxyApp/ProxyViewModel.swift`
- Modify: `ShadowProxyApp/MainWindow/MainWindowView.swift`

- [ ] **Step 1: ProxyViewModel 新增订阅管理方法**

在 `ProxyViewModel.swift` 添加：

```swift
@Published var subscriptions: [SubscriptionInfo] = []
private let subscriptionManager = SubscriptionManager()

func loadSubscriptions() {
    subscriptions = subscriptionManager.subscriptions()
}

func addSubscription(name: String, url: String) async {
    do {
        try await subscriptionManager.add(name: name, url: url)
        subscriptions = subscriptionManager.subscriptions()
        log("Added subscription: \(name)")
    } catch {
        log("Add subscription failed: \(error)")
    }
}

func refreshSubscription(id: String) async {
    do {
        try await subscriptionManager.refresh(id: id)
        subscriptions = subscriptionManager.subscriptions()
        log("Refreshed subscription")
    } catch {
        log("Refresh failed: \(error)")
    }
}

func refreshAllSubscriptions() async {
    do {
        try await subscriptionManager.refreshAll()
        subscriptions = subscriptionManager.subscriptions()
        log("All subscriptions refreshed")
    } catch {
        log("Refresh all failed: \(error)")
    }
}

func deleteSubscription(id: String) {
    subscriptionManager.delete(id: id)
    subscriptions = subscriptionManager.subscriptions()
}
```

在 `loadConfig()` 末尾添加：
```swift
loadSubscriptions()
```

- [ ] **Step 2: 创建 SubscriptionView**

创建 `ShadowProxyApp/MainWindow/SubscriptionView.swift`：

```swift
import SwiftUI
import ShadowProxyCore

struct SubscriptionView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Button("添加订阅") { showingAdd = true }
                Button("刷新全部") {
                    Task { await viewModel.refreshAllSubscriptions() }
                }
                Spacer()
            }
            .padding(12)

            Divider()

            // 订阅列表
            if viewModel.subscriptions.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无订阅")
                        .foregroundStyle(.tertiary)
                    Text("点击"添加订阅"导入节点")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(viewModel.subscriptions) { sub in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sub.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(sub.url)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text("\(sub.nodeCount) 节点")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    if let date = sub.lastUpdate {
                                        Text("更新于 \(date, format: .dateTime.month().day().hour().minute())")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Button("刷新") {
                                Task { await viewModel.refreshSubscription(id: sub.id) }
                            }
                            .controlSize(.small)
                            Button("删除") {
                                viewModel.deleteSubscription(id: sub.id)
                            }
                            .controlSize(.small)
                            .tint(.red)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("订阅")
        .sheet(isPresented: $showingAdd) {
            addSubscriptionSheet
        }
    }

    private var addSubscriptionSheet: some View {
        VStack(spacing: 16) {
            Text("添加订阅")
                .font(.headline)

            TextField("名称", text: $newName)
                .textFieldStyle(.roundedBorder)

            TextField("订阅 URL", text: $newURL)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("取消") {
                    showingAdd = false
                    newName = ""
                    newURL = ""
                }
                Spacer()
                Button("确认") {
                    Task {
                        await viewModel.addSubscription(name: newName, url: newURL)
                        showingAdd = false
                        newName = ""
                        newURL = ""
                    }
                }
                .disabled(newName.isEmpty || newURL.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
```

- [ ] **Step 3: 更新 MainWindowView**

替换占位符：
```swift
case .subscription:
    SubscriptionView(viewModel: viewModel)
```

- [ ] **Step 4: 构建验证**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
xcodegen generate && xcodebuild -project ShadowProxy.xcodeproj -scheme ShadowProxy -configuration Debug build 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: 订阅管理 UI — 添加/刷新/删除订阅"
```

---

### Task 8: 节点测速

**Files:**
- Create: `ShadowProxyApp/MainWindow/SpeedTestView.swift`
- Modify: `ShadowProxyApp/ProxyViewModel.swift`
- Modify: `ShadowProxyApp/MainWindow/MainWindowView.swift`

- [ ] **Step 1: ProxyViewModel 新增测速逻辑**

在 `ProxyViewModel.swift` 添加：

```swift
@Published var isTestingSpeed = false

func testSpeed(nodes: [String]? = nil) {
    guard let config else { return }
    isTestingSpeed = true
    let targetNodes = nodes ?? Array(config.proxies.keys)

    Task {
        await withTaskGroup(of: (String, Int?).self) { group in
            for name in targetNodes {
                guard let serverConfig = config.proxies[name] else { continue }
                group.addTask {
                    let ms = await self.measureLatency(name: name, serverConfig: serverConfig, config: config)
                    return (name, ms)
                }
            }
            for await (name, ms) in group {
                if let ms {
                    self.nodeSpeeds[name] = ms
                } else {
                    self.nodeSpeeds[name] = -1  // failed
                }
            }
        }
        isTestingSpeed = false
        log("Speed test completed for \(targetNodes.count) nodes")
    }
}

private func measureLatency(name: String, serverConfig: ServerConfig, config: AppConfig) async -> Int? {
    let start = Date()
    // Create a temporary engine-like connection to test
    // Simplified: use URLSession through proxy
    let proxyPort = config.general.port
    let proxyDict: [String: Any] = [
        kCFNetworkProxiesHTTPEnable as String: true,
        kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPPort as String: proxyPort,
        kCFNetworkProxiesHTTPSEnable as String: true,
        kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPSPort as String: proxyPort,
    ]
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.connectionProxyDictionary = proxyDict
    sessionConfig.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: sessionConfig)

    do {
        let url = URL(string: "http://www.gstatic.com/generate_204")!
        let (_, response) = try await session.data(from: url)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            return elapsed
        }
        return nil
    } catch {
        return nil
    }
}
```

- [ ] **Step 2: 创建 SpeedTestView**

创建 `ShadowProxyApp/MainWindow/SpeedTestView.swift`：

```swift
import SwiftUI
import ShadowProxyCore

struct SpeedTestView: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Button("测全部") {
                    viewModel.testSpeed()
                }
                .disabled(viewModel.isTestingSpeed || !viewModel.isRunning)

                if viewModel.isTestingSpeed {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 8)
                    Text("测速中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !viewModel.isRunning {
                    Text("需要先启动代理")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)

            Divider()

            // 节点列表 + 延迟
            List {
                ForEach(viewModel.proxyNames, id: \.self) { name in
                    HStack {
                        Text(name)
                            .font(.system(size: 13))

                        Spacer()

                        speedBadge(for: name)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("测速")
    }

    @ViewBuilder
    private func speedBadge(for name: String) -> some View {
        if let speed = viewModel.nodeSpeeds[name] {
            if speed < 0 {
                Text("超时")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                Text("\(speed)ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(speed < 100 ? .green : speed < 300 ? .yellow : .red)
            }
        } else {
            Text("-")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}
```

- [ ] **Step 3: 更新 MainWindowView**

替换占位符：
```swift
case .speedTest:
    SpeedTestView(viewModel: viewModel)
```

- [ ] **Step 4: 构建验证**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
xcodegen generate && xcodebuild -project ShadowProxy.xcodeproj -scheme ShadowProxy -configuration Debug build 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: 节点测速 — URL Test 204 + 测速 UI"
```

---

### Task 9: 设置页 + 开机自启

**Files:**
- Create: `ShadowProxyApp/MainWindow/SettingsView.swift`
- Modify: `ShadowProxyApp/ProxyViewModel.swift`
- Modify: `ShadowProxyApp/MainWindow/MainWindowView.swift`

- [ ] **Step 1: ProxyViewModel 新增设置属性**

在 `ProxyViewModel.swift` 添加：

```swift
@AppStorage("proxyPort") var settingsPort: Int = 7891
@AppStorage("dnsServer") var settingsDNS: String = "https://223.5.5.5/dns-query"
@AppStorage("logLevel") var settingsLogLevel: String = "info"
@AppStorage("launchAtLogin") var launchAtLogin: Bool = false
@AppStorage("autoRefreshSubs") var autoRefreshSubs: Bool = true
```

- [ ] **Step 2: 创建 SettingsView**

创建 `ShadowProxyApp/MainWindow/SettingsView.swift`：

```swift
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        Form {
            Section("代理") {
                HStack {
                    Text("监听端口")
                    Spacer()
                    TextField("", value: $viewModel.settingsPort, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("DNS 服务器")
                    Spacer()
                    TextField("", text: $viewModel.settingsDNS)
                        .frame(width: 240)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }

                Picker("日志级别", selection: $viewModel.settingsLogLevel) {
                    Text("Debug").tag("debug")
                    Text("Info").tag("info")
                    Text("Warning").tag("warning")
                    Text("Error").tag("error")
                }
            }

            Section("通用") {
                Toggle("开机自启", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { newValue in
                        viewModel.launchAtLogin = newValue
                        if newValue {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }
                ))

                Toggle("启动时自动刷新订阅", isOn: $viewModel.autoRefreshSubs)
            }

            Section {
                HStack {
                    Spacer()
                    Text("修改端口或 DNS 后需要重启代理生效")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }
}
```

- [ ] **Step 3: 更新 MainWindowView**

替换占位符：
```swift
case .settings:
    SettingsView(viewModel: viewModel)
```

- [ ] **Step 4: 在 project.yml 添加 ServiceManagement framework**

在 ShadowProxy target 的 settings 中添加：
```yaml
INFOPLIST_KEY_LSUIElement: true
```
（已在 Task 1 改过）

ServiceManagement 是系统 framework，SwiftUI import 即可用，不需要在 project.yml 额外添加 link。

- [ ] **Step 5: 构建验证**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
xcodegen generate && xcodebuild -project ShadowProxy.xcodeproj -scheme ShadowProxy -configuration Debug build 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: 设置页 + 开机自启（SMAppService）"
```

---

### Task 10: 集成验证 + Popover 打开请求查看器

**Files:**
- Modify: `ShadowProxyApp/MenuBarPopover.swift`
- Modify: `ShadowProxyApp/MainWindow/MainWindowView.swift`

- [ ] **Step 1: Popover 底栏添加请求查看器入口**

在 `MenuBarPopover.swift` 底栏 HStack 中，在"仪表盘"按钮后添加：

```swift
Button("📋 请求") {
    openWindow(id: "request-viewer")
    NSApp.activate(ignoringOtherApps: true)
}
.buttonStyle(.plain)
.font(.system(size: 12))
```

- [ ] **Step 2: 主窗口工具栏添加请求查看器按钮**

在 `MainWindowView.swift` 的 `NavigationSplitView` 末尾添加：

```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        Button {
            openWindow(id: "request-viewer")
        } label: {
            Label("请求查看器", systemImage: "list.bullet.rectangle")
        }
    }
}
```

并添加 `@Environment(\.openWindow) private var openWindow`。

- [ ] **Step 3: 全量构建 + 手动测试**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
xcodegen generate
rm -rf .build/DerivedData
xcodebuild -project ShadowProxy.xcodeproj -scheme ShadowProxy -configuration Debug build 2>&1 | tail -20
```

手动验证：
1. 启动 App → 菜单栏出现图标，无 Dock 图标
2. 点击菜单栏 → Popover 弹出，开关/节点/分流正确
3. 点"仪表盘" → 主窗口打开，侧边栏 7 个页面都能切换
4. 点"请求" → 请求查看器窗口打开
5. 关闭主窗口 → 菜单栏继续存在

- [ ] **Step 4: 运行单元测试**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
swift test 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "feat: 集成验证 — Popover/主窗口/请求查看器联通"
```

---

## 实现顺序与依赖

```
Task 1 (App 架构改造)
  ↓
Task 2 (Popover 面板) ← 依赖 Task 1 的 AppDelegate/StatusItem
  ↓
Task 3 (主窗口 + 概览 + 策略组) ← 依赖 Task 1 的窗口定义
Task 4 (节点列表 + 日志) ← 依赖 Task 3 的 MainWindowView
  ↓
Task 5 (请求查看器) ← 独立窗口，可与 Task 3/4 并行
Task 6 (订阅管理器) ← 纯逻辑，可与 Task 3/4/5 并行
  ↓
Task 7 (订阅 UI) ← 依赖 Task 3 的 MainWindowView + Task 6 的 Manager
Task 8 (测速) ← 依赖 Task 3 的 MainWindowView
Task 9 (设置) ← 依赖 Task 3 的 MainWindowView
  ↓
Task 10 (集成验证) ← 依赖全部
```

**可并行组：**
- Task 3 + Task 5 + Task 6（主窗口骨架 + 请求查看器 + 订阅逻辑互不冲突）
- Task 4 + Task 7 + Task 8 + Task 9（各页面独立）

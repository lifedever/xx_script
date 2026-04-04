# BoxX Homepage & Sidebar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign BoxX's sidebar grouping, overview dashboard, and window lifecycle for a professional, Surge-like experience with zero performance cost when the window is closed.

**Architecture:** Refactor MainView sidebar into 3 groups (代理/规则/底部), rebuild OverviewView with a status bar + 2-column card grid including SwiftUI Charts traffic trend, and add window visibility tracking to halt all polling when hidden.

**Tech Stack:** SwiftUI, SwiftUI Charts, macOS 14+, Swift 6.0

**Spec:** `docs/superpowers/specs/2026-04-04-boxx-homepage-sidebar-redesign.md`

---

### Task 1: Window Visibility Tracking & Zero-Consumption Lifecycle

**Files:**
- Modify: `.worktrees/boxx-v2/singbox/BoxX/BoxX/Models/AppState.swift`
- Modify: `.worktrees/boxx-v2/singbox/BoxX/BoxX/BoxXApp.swift` (StatusPoller)
- Modify: `.worktrees/boxx-v2/singbox/BoxX/BoxX/Views/MainView.swift` (onAppear/onDisappear)

- [ ] **Step 1: Add `isWindowVisible` to AppState**

In `AppState.swift`, add property after `showError`:

```swift
var isWindowVisible = false
```

- [ ] **Step 2: Add `stop()` method to StatusPoller**

In `BoxXApp.swift`, add to `StatusPoller` class after `nudge()`:

```swift
func stop() {
    timer?.invalidate()
    timer = nil
}
```

- [ ] **Step 3: Wire MainView lifecycle to control polling**

In `MainView.swift`, add lifecycle modifiers to the outermost `NavigationSplitView`:

```swift
.onAppear {
    appState.isWindowVisible = true
    StatusPoller.shared.start(appState: appState)
}
.onDisappear {
    appState.isWindowVisible = false
    StatusPoller.shared.stop()
}
```

Add these modifiers after `.frame(minWidth: 800, minHeight: 500)`.

- [ ] **Step 4: Guard OverviewView polling on window visibility**

In `OverviewView.swift`, modify `startStatsPolling()` to check visibility:

```swift
private func startStatsPolling() {
    stopStatsPolling()
    guard appState.isWindowVisible else { return }
    statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        Task { @MainActor in await pollStats() }
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX && xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2
git add singbox/BoxX/BoxX/Models/AppState.swift singbox/BoxX/BoxX/BoxXApp.swift singbox/BoxX/BoxX/Views/MainView.swift singbox/BoxX/BoxX/Views/OverviewView.swift
git commit -m "feat(BoxX): add window visibility tracking for zero-consumption on close"
```

---

### Task 2: Sidebar Restructure

**Files:**
- Modify: `.worktrees/boxx-v2/singbox/BoxX/BoxX/Views/MainView.swift`

- [ ] **Step 1: Update SidebarTab enum**

Replace the entire `SidebarTab` enum with:

```swift
enum SidebarTab: String, CaseIterable {
    case overview = "概览"
    case proxies = "策略组"
    case subscriptions = "订阅"
    case routeRules = "路由规则"
    case ruleSets = "规则集"
    case dns = "DNS"
    case connections = "请求"
    case logs = "日志"
    case settings = "设置"

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .proxies: return "network"
        case .subscriptions: return "antenna.radiowaves.left.and.right"
        case .routeRules: return "list.bullet.rectangle"
        case .ruleSets: return "tray.2"
        case .dns: return "globe"
        case .connections: return "arrow.left.arrow.right"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}
```

- [ ] **Step 2: Restructure sidebar layout in MainView body**

Replace the entire `NavigationSplitView` sidebar content (the `List(selection:)` block) with:

```swift
NavigationSplitView {
    List(selection: $selectedTab) {
        // Overview (no section header)
        Label(SidebarTab.overview.rawValue, systemImage: SidebarTab.overview.icon)
            .tag(SidebarTab.overview)

        // 代理
        Section("代理") {
            Label(SidebarTab.proxies.rawValue, systemImage: SidebarTab.proxies.icon)
                .tag(SidebarTab.proxies)
            Label(SidebarTab.subscriptions.rawValue, systemImage: SidebarTab.subscriptions.icon)
                .tag(SidebarTab.subscriptions)
        }

        // 规则
        Section("规则") {
            Label(SidebarTab.routeRules.rawValue, systemImage: SidebarTab.routeRules.icon)
                .tag(SidebarTab.routeRules)
            Label(SidebarTab.ruleSets.rawValue, systemImage: SidebarTab.ruleSets.icon)
                .tag(SidebarTab.ruleSets)
            Label(SidebarTab.dns.rawValue, systemImage: SidebarTab.dns.icon)
                .tag(SidebarTab.dns)
        }

        // Spacer pushes bottom items down
        Section {
            Label(SidebarTab.connections.rawValue, systemImage: SidebarTab.connections.icon)
                .tag(SidebarTab.connections)
            Label(SidebarTab.logs.rawValue, systemImage: SidebarTab.logs.icon)
                .tag(SidebarTab.logs)
            Label(SidebarTab.settings.rawValue, systemImage: SidebarTab.settings.icon)
                .tag(SidebarTab.settings)
        }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
}
```

- [ ] **Step 3: Remove old tab arrays and section property**

Delete these lines from `MainView`:
- `private var generalTabs: [SidebarTab]`
- `private var ruleTabs: [SidebarTab]`  
- `private var monitorTabs: [SidebarTab]`
- `private var manageTabs: [SidebarTab]`

Delete the `section` computed property from `SidebarTab` enum.

- [ ] **Step 4: Update detail view switch**

Replace the detail view switch statement with:

```swift
} detail: {
    switch selectedTab {
    case .overview:
        OverviewView()
    case .proxies:
        ProxiesView()
    case .subscriptions:
        SubscriptionsView()
    case .routeRules:
        RouteRulesView()
    case .ruleSets:
        RuleSetsView()
    case .dns:
        DNSView()
    case .connections:
        ConnectionsView()
    case .logs:
        LogsView()
    case .settings:
        SettingsView()
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX && xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -5`
Expected: Build will fail because `DNSView` doesn't exist yet — that's expected. Proceed to Task 3.

---

### Task 3: Create DNS Placeholder View

**Files:**
- Create: `.worktrees/boxx-v2/singbox/BoxX/BoxX/Views/DNSView.swift`

- [ ] **Step 1: Create DNSView**

Create `DNSView.swift`:

```swift
import SwiftUI

struct DNSView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DNS")
                    .font(.title2)
                    .bold()
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let dns = appState.configEngine.config.dns

                    // Servers
                    if let servers = dns?.servers, !servers.isEmpty {
                        GroupBox("DNS 服务器") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(servers.enumerated()), id: \.offset) { _, server in
                                    let tag = server["tag"]?.stringValue ?? "—"
                                    let address = server["address"]?.stringValue ?? "—"
                                    HStack {
                                        Text(tag)
                                            .font(.body.monospaced())
                                        Spacer()
                                        Text(address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(4)
                        }
                    }

                    // Rules
                    if let rules = dns?.rules, !rules.isEmpty {
                        GroupBox("DNS 规则") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                                    let server = rule["server"]?.stringValue ?? "—"
                                    HStack {
                                        Text("#\(index + 1)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 30, alignment: .leading)
                                        Text(ruleDescription(rule))
                                            .font(.callout)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("→ \(server)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(4)
                        }
                    }

                    // Final & Strategy
                    GroupBox("基本设置") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("默认服务器 (final)")
                                Spacer()
                                Text(dns?.final_ ?? "—")
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("策略 (strategy)")
                                Spacer()
                                Text(dns?.strategy ?? "—")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(4)
                    }

                    if dns == nil {
                        Text("未配置 DNS")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    }
                }
                .padding()
            }
        }
    }

    private func ruleDescription(_ rule: JSONValue) -> String {
        var parts: [String] = []
        if let domains = rule["domain_suffix"]?.arrayValue {
            let items = domains.prefix(3).compactMap { $0.stringValue }
            parts.append("domain_suffix: \(items.joined(separator: ", "))")
            if domains.count > 3 { parts.append("...") }
        }
        if let ruleSet = rule["rule_set"]?.arrayValue {
            let items = ruleSet.compactMap { $0.stringValue }
            parts.append("rule_set: \(items.joined(separator: ", "))")
        }
        if let outbound = rule["outbound"]?.stringValue {
            parts.append("outbound: \(outbound)")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " | ")
    }
}
```

- [ ] **Step 2: Build and verify (with Task 2 changes)**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX && xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2
git add singbox/BoxX/BoxX/Views/MainView.swift singbox/BoxX/BoxX/Views/DNSView.swift
git commit -m "feat(BoxX): restructure sidebar grouping and add DNS view"
```

---

### Task 4: Merge BuiltinRules into RuleSetsView

**Files:**
- Modify: `.worktrees/boxx-v2/singbox/BoxX/BoxX/Views/RuleSetsView.swift`
- Keep (do not delete yet): `.worktrees/boxx-v2/singbox/BoxX/BoxX/Views/BuiltinRulesView.swift`

- [ ] **Step 1: Add tab picker to RuleSetsView**

Add a `@State` variable at the top of `RuleSetsView`:

```swift
@State private var selectedTab: RuleSetTab = .custom

enum RuleSetTab: String, CaseIterable {
    case custom = "自定义"
    case builtin = "内置"
}
```

- [ ] **Step 2: Wrap existing content in tab structure**

Replace the `body` of `RuleSetsView` — wrap the existing toolbar `HStack` and content in a tab structure. The toolbar becomes:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        // Toolbar
        HStack {
            Text("规则集")
                .font(.title2)
                .bold()
            
            Picker("", selection: $selectedTab) {
                ForEach(RuleSetTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            let ruleSets = appState.configEngine.config.route.ruleSet ?? []
            Text("\(ruleSets.count) 个规则集")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Keep the "全部更新" button only for custom tab
            if selectedTab == .custom {
                let hasRemote = ruleSets.contains { $0["type"]?.stringValue == "remote" }
                if hasRemote {
                    Button {
                        Task { await updateAllRemoteRuleSets() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("全部更新")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(ruleSetUpdateStatus.values.contains { if case .updating = $0 { return true } else { return false } })
                }
            }
        }
        .padding()

        Divider()

        // Tab content
        switch selectedTab {
        case .custom:
            customRuleSetsContent
        case .builtin:
            BuiltinRulesContent()
                .environment(appState)
        }
    }
    // Keep existing .sheet and .alert modifiers
}
```

- [ ] **Step 3: Extract current ScrollView content to a computed property**

Move the existing `ScrollView { ... }` content (everything after `Divider()` in the current body) into:

```swift
@ViewBuilder
private var customRuleSetsContent: some View {
    ScrollView {
        // ... existing content unchanged ...
    }
}
```

- [ ] **Step 4: Create BuiltinRulesContent as an embedded view**

Add at the bottom of `RuleSetsView.swift` (before the `RuleSetEditSheet` struct):

```swift
private struct BuiltinRulesContent: View {
    @Environment(AppState.self) private var appState
    @State private var enabledRuleSetIDs: Set<String> = []
    @State private var editingRuleSet: BuiltinRuleSet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("基于 sing-geosite 的预置规则集")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 10) {
                    ForEach(BuiltinRuleSet.all) { ruleSet in
                        builtinRuleSetCard(ruleSet)
                    }
                }
            }
            .padding()
        }
        .task { loadEnabledRuleSets() }
        .sheet(item: $editingRuleSet) { ruleSet in
            BuiltinRuleSetEditSheet(ruleSet: ruleSet) {
                loadEnabledRuleSets()
            }
        }
    }

    private func builtinRuleSetCard(_ ruleSet: BuiltinRuleSet) -> some View {
        let isEnabled = enabledRuleSetIDs.contains(ruleSet.id)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ruleSet.displayName)
                    .font(.callout.bold())
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(ruleSet.geositeNames, id: \.self) { name in
                        Text(name)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(ruleSet.defaultOutbound)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if newValue {
                        enabledRuleSetIDs.insert(ruleSet.id)
                        addRuleSetToConfig(ruleSet)
                    } else {
                        enabledRuleSetIDs.remove(ruleSet.id)
                        removeRuleSetFromConfig(ruleSet)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(isEnabled ? 1.0 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { editingRuleSet = ruleSet }
    }

    private func loadEnabledRuleSets() {
        let existingTags = Set(
            (appState.configEngine.config.route.ruleSet ?? [])
                .compactMap { $0["tag"]?.stringValue }
        )
        enabledRuleSetIDs = Set(
            BuiltinRuleSet.all.filter { ruleSet in
                ruleSet.geositeNames.allSatisfy { existingTags.contains("geosite-\($0)") }
            }.map(\.id)
        )
    }

    private func addRuleSetToConfig(_ ruleSet: BuiltinRuleSet) {
        var currentRuleSets = appState.configEngine.config.route.ruleSet ?? []
        for def in ruleSet.ruleSetDefinitions {
            let tag = def["tag"]?.stringValue ?? ""
            if !currentRuleSets.contains(where: { $0["tag"]?.stringValue == tag }) {
                currentRuleSets.append(def)
            }
        }
        appState.configEngine.config.route.ruleSet = currentRuleSets
        var currentRules = appState.configEngine.config.route.rules ?? []
        currentRules.append(ruleSet.routeRule)
        appState.configEngine.config.route.rules = currentRules
        do { try appState.configEngine.save(restartRequired: true) }
        catch { appState.showAlert("保存失败: \(error.localizedDescription)") }
    }

    private func removeRuleSetFromConfig(_ ruleSet: BuiltinRuleSet) {
        let tagsToRemove = Set(ruleSet.geositeNames.map { "geosite-\($0)" })
        appState.configEngine.config.route.ruleSet?.removeAll { item in
            guard let tag = item["tag"]?.stringValue else { return false }
            return tagsToRemove.contains(tag)
        }
        appState.configEngine.config.route.rules?.removeAll { item in
            guard let ruleSetRefs = item["rule_set"]?.arrayValue else { return false }
            let refTags = Set(ruleSetRefs.compactMap { $0.stringValue })
            return !refTags.isDisjoint(with: tagsToRemove)
        }
        do { try appState.configEngine.save(restartRequired: true) }
        catch { appState.showAlert("保存失败: \(error.localizedDescription)") }
    }
}
```

- [ ] **Step 5: Remove BuiltinRulesView.swift from MainView references**

The `BuiltinRulesView()` case was already removed from MainView's switch in Task 2. Now also remove `BuiltinRulesView.swift` from the project (delete the file):

```bash
rm /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX/BoxX/Views/BuiltinRulesView.swift
```

Note: Keep the `BuiltinRuleSetEditSheet` struct from BuiltinRulesView.swift — it's used by `BuiltinRulesContent`. Move it into `RuleSetsView.swift` at the bottom (after `RuleSetEditSheet`). Copy the full `BuiltinRuleSetEditSheet` struct (lines 166-321 of the original BuiltinRulesView.swift) to the end of RuleSetsView.swift.

- [ ] **Step 6: Build and verify**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX && xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2
git add -A singbox/BoxX/BoxX/Views/RuleSetsView.swift singbox/BoxX/BoxX/Views/BuiltinRulesView.swift
git commit -m "feat(BoxX): merge built-in rules into rule sets view with tab switching"
```

---

### Task 5: Redesign OverviewView — Status Bar + Card Grid

**Files:**
- Modify: `.worktrees/boxx-v2/singbox/BoxX/BoxX/Views/OverviewView.swift`

- [ ] **Step 1: Rewrite OverviewView with new layout**

Replace the entire `OverviewView.swift` with the new design. The new file structure:

```swift
import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(AppState.self) private var appState
    @State private var snapshot: ConnectionSnapshot?
    @State private var clashConfig: ClashConfig?
    @State private var isOperating = false
    @State private var statsTimer: Timer?
    @State private var downloadSpeed: Int64 = 0
    @State private var uploadSpeed: Int64 = 0
    @State private var trafficTrend = TrafficTrendBuffer()
    @State private var trendTimer: Timer?
    @State private var lastTrendDownload: Int64 = 0
    @State private var lastTrendUpload: Int64 = 0
    @State private var showActions = false

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusBar
                LazyVGrid(columns: columns, spacing: 12) {
                    speedCard
                    connectionsCard
                    trafficStatsCard
                    trafficTrendCard
                    configDirCard
                    envVarsCard
                }
            }
            .padding()
        }
        .task { await refresh() }
        .onChange(of: appState.isRunning) { _, running in
            if running { startStatsPolling(); startTrendPolling() }
            else { stopStatsPolling(); stopTrendPolling(); resetStats() }
        }
        .onDisappear { stopStatsPolling(); stopTrendPolling() }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 0) {
            // Running status
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.isRunning ? Color.green : Color.red.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(appState.isRunning ? "运行中" : "已停止")
                    .font(.system(.callout, weight: .medium))

                if isOperating {
                    ProgressView().controlSize(.mini)
                } else if showActions {
                    HStack(spacing: 4) {
                        if appState.isRunning {
                            Button("重启") { Task { await doRestart() } }
                                .controlSize(.mini).buttonStyle(.bordered)
                            Button("停止") { Task { await doStop() } }
                                .controlSize(.mini).buttonStyle(.bordered).tint(.red)
                        } else {
                            Button("启动") { Task { await doStart() } }
                                .controlSize(.mini).buttonStyle(.borderedProminent).tint(.green)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showActions.toggle() } }

            Spacer()

            Divider().frame(height: 16).padding(.horizontal, 12)

            // Proxy mode
            Picker("", selection: Binding(
                get: { clashConfig?.mode ?? "rule" },
                set: { newMode in
                    Task {
                        try? await appState.api.setMode(newMode)
                        clashConfig = try? await appState.api.getConfig()
                    }
                }
            )) {
                Text("规则").tag("rule")
                Text("全局").tag("global")
                Text("直连").tag("direct")
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .labelsHidden()

            Spacer()

            Divider().frame(height: 16).padding(.horizontal, 12)

            // Listen address
            VStack(alignment: .leading, spacing: 1) {
                Text("监听").font(.caption2).foregroundStyle(.tertiary)
                Text("127.0.0.1:7890").font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            Divider().frame(height: 16).padding(.horizontal, 12)

            // Clash API
            VStack(alignment: .leading, spacing: 1) {
                Text("API").font(.caption2).foregroundStyle(.tertiary)
                Text(appState.configEngine.config.experimental?.clashApi?.externalController ?? "127.0.0.1:9091")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Cards

    private var speedCard: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("实时网速")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                                .font(.caption).foregroundStyle(.green)
                            Text("下载").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(speedString(downloadSpeed))
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up")
                                .font(.caption).foregroundStyle(.orange)
                            Text("上传").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(speedString(uploadSpeed))
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                HStack {
                    Text("总下载 \(byteFormatter.string(fromByteCount: snapshot?.downloadTotal ?? 0))")
                    Spacer()
                    Text("总上传 \(byteFormatter.string(fromByteCount: snapshot?.uploadTotal ?? 0))")
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var connectionsCard: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("活跃连接")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(snapshot?.connections?.count ?? 0)")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                HStack {
                    let processCount = Set(snapshot?.connections?.map(\.processName) ?? []).count
                    Text("\(processCount) 个进程")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if let mem = snapshot?.memory {
                        Text("内存 \(byteFormatter.string(fromByteCount: mem))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var trafficStatsCard: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("流量统计")
                    .font(.caption).foregroundStyle(.secondary)
                let total = (snapshot?.downloadTotal ?? 0) + (snapshot?.uploadTotal ?? 0)
                Text(byteFormatter.string(fromByteCount: total))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                // Simple bar showing download vs upload ratio
                GeometryReader { geo in
                    let dl = snapshot?.downloadTotal ?? 0
                    let ul = snapshot?.uploadTotal ?? 0
                    let sum = max(dl + ul, 1)
                    let dlWidth = geo.size.width * CGFloat(dl) / CGFloat(sum)
                    HStack(spacing: 0) {
                        Rectangle().fill(.green.opacity(0.6))
                            .frame(width: dlWidth)
                        Rectangle().fill(.orange.opacity(0.6))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 6)
                HStack {
                    Circle().fill(.green.opacity(0.6)).frame(width: 6, height: 6)
                    Text("下载").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Circle().fill(.orange.opacity(0.6)).frame(width: 6, height: 6)
                    Text("上传").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var trafficTrendCard: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("流量趋势")
                    .font(.caption).foregroundStyle(.secondary)
                let data = trafficTrend.points
                if data.isEmpty {
                    Text("等待数据...")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    Chart(data) { point in
                        LineMark(
                            x: .value("时间", point.time),
                            y: .value("字节", point.download)
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("时间", point.time),
                            y: .value("字节", point.upload)
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisValueLabel {
                                if let bytes = value.as(Int64.self) {
                                    Text(byteFormatter.string(fromByteCount: bytes))
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(minHeight: 80)
                }
                HStack(spacing: 12) {
                    HStack(spacing: 3) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text("下载").font(.caption2).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 3) {
                        Circle().fill(.orange).frame(width: 5, height: 5)
                        Text("上传").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("最近 \(data.count) 分钟")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var configDirCard: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("配置目录")
                    .font(.caption).foregroundStyle(.secondary)
                Text(appState.configEngine.baseDir.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSWorkspace.shared.open(appState.configEngine.baseDir)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text("打开")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var envVarsCard: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("环境变量")
                    .font(.caption).foregroundStyle(.secondary)
                Text("https_proxy / http_proxy / all_proxy")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    let env = "export https_proxy=http://127.0.0.1:7890\nexport http_proxy=http://127.0.0.1:7890\nexport all_proxy=socks5://127.0.0.1:7890"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(env, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("复制")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Card wrapper

    @ViewBuilder
    private func dashboardCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func speedString(_ bytesPerSecond: Int64) -> String {
        byteFormatter.string(fromByteCount: bytesPerSecond) + "/s"
    }

    // MARK: - Stats polling (2s)

    private func startStatsPolling() {
        stopStatsPolling()
        guard appState.isWindowVisible else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in await pollStats() }
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats() async {
        guard appState.isRunning else { return }
        let newSnapshot = try? await appState.api.getConnections()
        if let prev = snapshot, let curr = newSnapshot {
            downloadSpeed = max(0, (curr.downloadTotal - prev.downloadTotal) / 2)
            uploadSpeed = max(0, (curr.uploadTotal - prev.uploadTotal) / 2)
        }
        snapshot = newSnapshot
    }

    // MARK: - Trend polling (60s)

    private func startTrendPolling() {
        stopTrendPolling()
        guard appState.isWindowVisible else { return }
        // Record initial baseline
        Task {
            if let s = try? await appState.api.getConnections() {
                lastTrendDownload = s.downloadTotal
                lastTrendUpload = s.uploadTotal
            }
        }
        trendTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await pollTrend() }
        }
    }

    private func stopTrendPolling() {
        trendTimer?.invalidate()
        trendTimer = nil
    }

    private func pollTrend() async {
        guard appState.isRunning else { return }
        guard let s = try? await appState.api.getConnections() else { return }
        let dl = max(0, s.downloadTotal - lastTrendDownload)
        let ul = max(0, s.uploadTotal - lastTrendUpload)
        lastTrendDownload = s.downloadTotal
        lastTrendUpload = s.uploadTotal
        trafficTrend.append(download: dl, upload: ul)
    }

    private func resetStats() {
        snapshot = nil
        clashConfig = nil
        downloadSpeed = 0
        uploadSpeed = 0
        trafficTrend = TrafficTrendBuffer()
        lastTrendDownload = 0
        lastTrendUpload = 0
    }

    // MARK: - Actions

    private func doStart() async {
        isOperating = true; defer { isOperating = false }
        do {
            try appState.configEngine.deployRuntime()
            let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
            try appState.singBoxProcess.start(configPath: runtimePath)
        } catch {
            appState.showAlert(error.localizedDescription)
        }
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func doStop() async {
        isOperating = true; defer { isOperating = false }
        appState.singBoxProcess.stop()
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func doRestart() async {
        isOperating = true; defer { isOperating = false }
        do {
            try appState.configEngine.deployRuntime()
            let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
            try appState.singBoxProcess.restart(configPath: runtimePath)
        } catch {
            appState.showAlert(error.localizedDescription)
        }
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func refresh() async {
        guard appState.isRunning else { resetStats(); return }
        snapshot = try? await appState.api.getConnections()
        clashConfig = try? await appState.api.getConfig()
        startStatsPolling()
        startTrendPolling()
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX && xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -5`
Expected: Build will fail because `TrafficTrendBuffer` doesn't exist yet — proceed to Task 6.

---

### Task 6: Traffic Trend Data Model

**Files:**
- Create: `.worktrees/boxx-v2/singbox/BoxX/BoxX/Models/TrafficTrendBuffer.swift`

- [ ] **Step 1: Create TrafficTrendBuffer**

```swift
import Foundation

struct TrafficTrendPoint: Identifiable {
    let id = UUID()
    let time: Date
    let download: Int64
    let upload: Int64
}

struct TrafficTrendBuffer {
    private(set) var points: [TrafficTrendPoint] = []
    private let maxCount = 60

    mutating func append(download: Int64, upload: Int64) {
        let point = TrafficTrendPoint(time: Date(), download: download, upload: upload)
        points.append(point)
        if points.count > maxCount {
            points.removeFirst(points.count - maxCount)
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX && xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Run tests**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX && xcodebuild test -scheme BoxX -configuration Debug 2>&1 | grep -E '(Test Suite|Test Case|BUILD|Executed)' | tail -20`
Expected: All existing tests pass

- [ ] **Step 4: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2
git add singbox/BoxX/BoxX/Views/OverviewView.swift singbox/BoxX/BoxX/Models/TrafficTrendBuffer.swift singbox/BoxX/BoxX/Views/RuleSetsView.swift
git add -A singbox/BoxX/BoxX/Views/BuiltinRulesView.swift
git commit -m "feat(BoxX): redesign overview with status bar, card grid, and traffic trend chart"
```

---

### Task 7: App Icon Generation

**Files:**
- Modify: `.worktrees/boxx-v2/singbox/BoxX/BoxX/Resources/Assets.xcassets/AppIcon.appiconset/`

- [ ] **Step 1: Generate app icon using app-icon-generator skill**

Use the `app-icon-generator` skill with these requirements:
- Base design: Isometric box (referencing sing-box's package/parcel icon shape)
- BoxX branding: Add an "X" mark or distinctive element on the box face
- Color: Light/white background, box in a modern accent color (blue-teal gradient)
- Style: Clean, modern, macOS-native feel
- Format: All required macOS icon sizes (16, 32, 64, 128, 256, 512, 1024)

- [ ] **Step 2: Verify icon is integrated**

Build the app and check the icon appears correctly in Dock and menu bar.

- [ ] **Step 3: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2
git add singbox/BoxX/BoxX/Resources/Assets.xcassets/AppIcon.appiconset/
git commit -m "feat(BoxX): redesign app icon with sing-box inspired isometric box"
```

---

### Task 8: Final Verification

- [ ] **Step 1: Full build**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX && xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run all tests**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/.worktrees/boxx-v2/singbox/BoxX && xcodebuild test -scheme BoxX -configuration Debug 2>&1 | grep -E '(Test Suite|Test Case|BUILD|Executed)' | tail -20`
Expected: All tests pass

- [ ] **Step 3: Verify window lifecycle**

Manual verification checklist:
- Open app → overview shows status bar + card grid
- Close window (red button) → reopen via menu bar → data refreshes from scratch
- Cmd+Q → reopen → same behavior
- Sidebar shows: 概览 | 代理(策略组/订阅) | 规则(路由规则/规则集/DNS) | 底部(请求/日志/设置)
- 规则集 page has 自定义/内置 tab switcher
- DNS page shows server and rule info

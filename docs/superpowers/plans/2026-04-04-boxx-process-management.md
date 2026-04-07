# BoxX 进程管理优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 优化 BoxX 的 sing-box 进程管理，解决 deployRuntime 重复调用、SIGHUP 后探测不可靠、DNS 刷新不完整、启动就绪检查低效等问题。

**Architecture:** 将 ConfigEngine/AppState/SingBoxProcess 的职责理清为单向依赖。applyConfig 拆分为 reloadConfig（SIGHUP）和 restartProcess（full restart）两条路径。连通性探测从 HTTP 代理端口改为 Clash API 可达性检查。DNS 刷新扩展为 sing-box 内部 + 系统三层清理。

**Tech Stack:** Swift, SwiftUI, XPC (HelperProtocol), sing-box Clash API

---

### Task 1: ClashAPI -- 新增 DNS/FakeIP 缓存刷新 + post 方法

**Files:**
- Modify: `BoxX/Services/ClashAPI.swift`

- [ ] **Step 1: 添加 post 方法和 DNS 刷新方法**

在 `ClashAPI.swift` 的 `delete` 方法之后、`addAuth` 方法之前，添加：

```swift
    private func post(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
```

在 `closeAllConnections` 方法之后添加：

```swift
    /// Flush sing-box internal DNS cache (calls dnsRouter.ClearCache)
    func flushDNSCache() async throws { _ = try await post("/cache/dns/flush") }

    /// Flush sing-box FakeIP cache (calls cacheFile.FakeIPReset)
    func flushFakeIPCache() async throws { _ = try await post("/cache/fakeip/flush") }
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX && xcodebuild -project BoxX.xcodeproj -scheme BoxX -configuration Debug build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add BoxX/Services/ClashAPI.swift
git commit -m "feat(ClashAPI): add flushDNSCache and flushFakeIPCache methods"
```

---

### Task 2: SingBoxProcess -- 重构 start() 为 async waitForReady

**Files:**
- Modify: `BoxX/Services/SingBoxProcess.swift`

- [ ] **Step 1: 添加 waitForReady 方法**

在 `SingBoxProcess` class 内，`checkClashAPISync()` 方法之前添加：

```swift
    /// Poll Clash API with exponential backoff until ready.
    /// Returns true if ready within timeout, false otherwise.
    private nonisolated func waitForClashAPI(timeout: TimeInterval = 60) -> Bool {
        let start = Date()
        var interval: TimeInterval = 0.2
        while Date().timeIntervalSince(start) < timeout {
            if checkClashAPISync() { return true }
            Thread.sleep(forTimeInterval: interval)
            interval = min(interval * 2, 1.0) // 200ms → 400ms → 800ms → 1s cap
        }
        return false
    }
```

- [ ] **Step 2: 重构 start() 方法的就绪检查部分**

将 `start()` 方法中的就绪轮询代码（从 `progressMessage = "正在等待 sing-box 就绪..."` 开始到 `throw SingBoxError.startFailed("sing-box 启动后退出，请检查配置")` 之前）替换为：

找到这段旧代码：
```swift
        progressMessage = "正在等待 sing-box 就绪..."

        // Wait for Clash API (up to 60s for first-time rule-set downloads)
        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                for _ in 0..<120 {
                    if self.checkClashAPISync() { cont.resume(returning: true); return }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                cont.resume(returning: false)
            }
        }
```

替换为：
```swift
        progressMessage = "正在等待 sing-box 就绪..."

        // Wait for Clash API with exponential backoff (up to 60s for first-time rule-set downloads)
        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                cont.resume(returning: self.waitForClashAPI(timeout: 60))
            }
        }
```

- [ ] **Step 3: 去掉 start() 末尾的双重 flushDNS + sleep**

找到并删除 `start()` 方法末尾的这段代码（在 `isRunning = true` 和最后一个 `}` 之间）：

```swift
        // Wait for TUN route table to stabilize, then flush DNS
        if isRunning {
            try? await Task.sleep(for: .seconds(2))
            flushDNS()
            try? await Task.sleep(for: .seconds(1))
            flushDNS()
        }
```

替换为（DNS 刷新由调用方在 start 之后统一执行）：
```swift
        // DNS flush is handled by the caller (AppState) after start completes
```

- [ ] **Step 4: 验证编译**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX && xcodebuild -project BoxX.xcodeproj -scheme BoxX -configuration Debug build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add BoxX/Services/SingBoxProcess.swift
git commit -m "refactor(SingBoxProcess): exponential backoff for startup, remove hardcoded sleeps"
```

---

### Task 3: ConfigEngine -- onDeployComplete 只设标记

**Files:**
- Modify: `BoxX/Services/ConfigEngine.swift`

- [ ] **Step 1: 将 onDeployComplete 回调类型改为更明确的名称**

不改 ConfigEngine 内部。`onDeployComplete` 回调保持不变（它只是一个 `(() -> Void)?`）。改动在 AppState 侧（Task 4）。这一步只需确认 ConfigEngine 的 `deployRuntime` 在 `autoApply: false` 时不调用回调：

检查 `ConfigEngine.swift` 中 `deployRuntime` 的两处 `onDeployComplete` 调用：
- 第 630 行：`if skipValidation { if autoApply { onDeployComplete?() } ... }`
- 第 703 行：`if autoApply { onDeployComplete?() }`

这两处已经受 `autoApply` 参数控制。不需要改 ConfigEngine 的代码。

- [ ] **Step 2: Commit (no-op, document decision)**

无代码改动。ConfigEngine 的 `autoApply` 参数已经能控制是否触发回调。改动集中在 AppState 侧。

---

### Task 4: AppState -- 核心重构

**Files:**
- Modify: `BoxX/Models/AppState.swift`

- [ ] **Step 1: 添加 pendingRestart 属性**

在 `pendingReload` 属性之后添加：

```swift
    var pendingRestart: Bool {
        didSet { UserDefaults.standard.set(pendingRestart, forKey: "pendingRestart") }
    }
```

在 `init()` 中 `pendingReload = ...` 之后添加：

```swift
        pendingRestart = UserDefaults.standard.bool(forKey: "pendingRestart")
```

- [ ] **Step 2: 简化 onDeployComplete 回调**

将 `init()` 中的 `onDeployComplete` 闭包：

```swift
        configEngine.onDeployComplete = { [weak self] in
            Task { @MainActor in
                guard let self, self.startupComplete, self.singBoxProcess.isRunning else { return }
                self.pendingReload = true
                await self.applyConfig()
            }
        }
```

替换为（只设标记，不触发 apply）：

```swift
        configEngine.onDeployComplete = { [weak self] in
            Task { @MainActor in
                guard let self, self.startupComplete, self.singBoxProcess.isRunning else { return }
                self.pendingReload = true
            }
        }
```

- [ ] **Step 3: 添加 validateConfig 方法**

在 `showAlert` 方法之后添加：

```swift
    /// Validate runtime-config.json with sing-box check
    private func validateConfig() async -> Bool {
        let rtPath = configEngine.baseDir.appendingPathComponent("runtime-config.json").path
        return await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")
            proc.arguments = ["check", "-c", rtPath]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        }.value
    }
```

- [ ] **Step 4: 添加 waitForClashAPI 方法**

```swift
    /// Poll Clash API until it becomes reachable. Returns true if reachable within timeout.
    private func waitForClashAPI(timeout: TimeInterval = 3.0, interval: TimeInterval = 0.2) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await api.isReachable() { return true }
            try? await Task.sleep(for: .seconds(interval))
        }
        return false
    }
```

- [ ] **Step 5: 添加 flushAllDNS 方法**

```swift
    /// Three-layer DNS flush: sing-box internal DNS cache + FakeIP cache + system DNS cache
    func flushAllDNS() async {
        // 1 & 2: sing-box internal caches (ignore errors — API may not be ready yet)
        try? await api.flushDNSCache()
        try? await api.flushFakeIPCache()
        // 3: system DNS cache (via Helper as root)
        singBoxProcess.flushDNS()
    }
```

- [ ] **Step 6: 添加 reloadConfig 方法**

```swift
    /// SIGHUP path: for config/rule/node changes (no TUN teardown)
    private func reloadConfig() async {
        let rtPath = configEngine.baseDir.appendingPathComponent("runtime-config.json").path

        // Send SIGHUP — sing-box will Close old instance + Create/Start new instance
        await singBoxProcess.reload()

        // Wait for Clash API to come back (signals all components including TUN are ready)
        let ready = await waitForClashAPI(timeout: 3.0, interval: 0.2)

        if ready {
            await flushAllDNS()
            try? await api.closeAllConnections()
        } else {
            // SIGHUP failed to recover — escalate to full restart
            print("[BoxX] Clash API not reachable after SIGHUP, escalating to full restart...")
            await restartProcess()
        }
    }
```

- [ ] **Step 7: 添加 restartProcess 方法**

```swift
    /// Full restart path: for TUN/inbound/port changes
    private func restartProcess() async {
        let rtPath = configEngine.baseDir.appendingPathComponent("runtime-config.json").path

        await singBoxProcess.stop()
        do {
            try await singBoxProcess.start(configPath: rtPath, mixedPort: configEngine.mixedPort)
            await flushAllDNS()
            try? await api.closeAllConnections()
        } catch {
            showAlert("重启失败: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 8: 替换 applyConfig 方法**

删除现有的 `applyConfig()` 和 `probeConnectivity()` 方法（第 100-188 行），替换为：

```swift
    /// Apply pending config changes — routes to SIGHUP reload or full restart based on pendingRestart flag
    func applyConfig() async {
        guard isRunning, pendingReload, !isApplyingConfig, !isRestarting else { return }
        isApplyingConfig = true
        defer { isApplyingConfig = false }

        // Validate config before applying
        guard await validateConfig() else {
            showAlert("配置校验失败，请检查后重试。不会应用当前配置。")
            return
        }

        if pendingRestart {
            await restartProcess()
        } else {
            await reloadConfig()
        }

        pendingReload = false
        pendingRestart = false
    }
```

- [ ] **Step 9: 验证编译**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX && xcodebuild -project BoxX.xcodeproj -scheme BoxX -configuration Debug build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 10: Commit**

```bash
git add BoxX/Models/AppState.swift
git commit -m "refactor(AppState): split applyConfig into reloadConfig/restartProcess, add 3-layer DNS flush"
```

---

### Task 5: SettingsView -- TUN/端口变更设 pendingRestart

**Files:**
- Modify: `BoxX/Views/SettingsView.swift`

- [ ] **Step 1: TUN 模式开关设 pendingRestart**

找到 GeneralTab 中的 TUN 模式 Toggle（约第 75-78 行）：

```swift
                Toggle("TUN 模式", isOn: $tunEnabled)
                    .onChange(of: tunEnabled) { _, _ in
                        appState.pendingReload = true
                    }
```

替换为：

```swift
                Toggle("TUN 模式", isOn: $tunEnabled)
                    .onChange(of: tunEnabled) { _, _ in
                        appState.pendingReload = true
                        appState.pendingRestart = true
                    }
```

- [ ] **Step 2: AdvancedTab 的保存逻辑设 pendingRestart**

找到 `saveAdvanced()` 方法中的保存逻辑。在 `try appState.configEngine.save(restartRequired: true)` 之前添加一行：

```swift
            appState.pendingRestart = true
```

这样协议栈、IPv6、TUN 排除地址、日志级别等高级设置的保存都会走 full restart 路径。

- [ ] **Step 3: 验证编译**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX && xcodebuild -project BoxX.xcodeproj -scheme BoxX -configuration Debug build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add BoxX/Views/SettingsView.swift
git commit -m "feat(SettingsView): set pendingRestart for TUN/inbound changes"
```

---

### Task 6: MenuBarController -- 适配新流程

**Files:**
- Modify: `BoxX/MenuBar/MenuBarController.swift`

- [ ] **Step 1: 启动流程适配**

找到 `startSingBox()` 方法中启动成功后的 flushDNS 调用（约第 401-403 行）：

```swift
                appState.singBoxProcess.flushDNS()
                try? await appState.api.closeAllConnections()
```

替换为：

```swift
                await appState.flushAllDNS()
                try? await appState.api.closeAllConnections()
```

- [ ] **Step 2: 重启流程适配**

找到 `restartSingBox()` 方法中重启成功后的代码（约第 437-439 行）：

```swift
                appState.singBoxProcess.flushDNS()
                try? await appState.api.closeAllConnections()
```

替换为：

```swift
                await appState.flushAllDNS()
                try? await appState.api.closeAllConnections()
```

- [ ] **Step 3: setTUN 适配**

找到 `setTUN()` 方法（约第 547-556 行）：

```swift
    private func setTUN(_ enabled: Bool) {
        let current = UserDefaults.standard.object(forKey: "tunEnabled") as? Bool ?? true
        guard enabled != current else { return }
        UserDefaults.standard.set(enabled, forKey: "tunEnabled")
        appState.pendingReload = true
        Task {
            await appState.applyConfig()
```

替换为：

```swift
    private func setTUN(_ enabled: Bool) {
        let current = UserDefaults.standard.object(forKey: "tunEnabled") as? Bool ?? true
        guard enabled != current else { return }
        UserDefaults.standard.set(enabled, forKey: "tunEnabled")
        appState.pendingReload = true
        appState.pendingRestart = true
        Task {
            try? appState.configEngine.deployRuntime(autoApply: false)
            await appState.applyConfig()
```

- [ ] **Step 4: 订阅更新-全部 适配**

找到菜单栏的全部订阅更新完成后的 reload 代码（约第 614-618 行）：

```swift
            await appState.singBoxProcess.reload()
            appState.singBoxProcess.flushDNS()
            try? await appState.api.closeAllConnections()
            appState.pendingReload = false
```

替换为：

```swift
            appState.pendingReload = true
            await appState.applyConfig()
```

- [ ] **Step 5: 订阅更新-单个 适配**

找到单个订阅更新完成后的 reload 代码（约第 632-635 行）：

```swift
                await appState.singBoxProcess.reload()
                appState.singBoxProcess.flushDNS()
                try? await appState.api.closeAllConnections()
                appState.pendingReload = false
```

替换为：

```swift
                appState.pendingReload = true
                await appState.applyConfig()
```

- [ ] **Step 6: reloadSingBox 菜单项适配**

找到 `reloadSingBox()` 方法（约第 530-537 行）：

```swift
    @objc private func reloadSingBox() {
        Task {
            await appState.singBoxProcess.reload()
            appState.singBoxProcess.flushDNS()
            // 关闭所有连接，强制重建
            try? await appState.api.closeAllConnections()
            StatusPoller.shared.nudge(appState: appState)
        }
    }
```

替换为：

```swift
    @objc private func reloadSingBox() {
        Task {
            appState.pendingReload = true
            try? appState.configEngine.deployRuntime(autoApply: false)
            await appState.applyConfig()
            StatusPoller.shared.nudge(appState: appState)
        }
    }
```

- [ ] **Step 7: 验证编译**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX && xcodebuild -project BoxX.xcodeproj -scheme BoxX -configuration Debug build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add BoxX/MenuBar/MenuBarController.swift
git commit -m "refactor(MenuBar): route all reload/restart through applyConfig, use flushAllDNS"
```

---

### Task 7: 集成测试 -- 构建并验证

**Files:**
- All modified files

- [ ] **Step 1: Full build**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX && ./build.sh full 2>&1 | tail -10`
Expected: BUILD SUCCEEDED, BoxX installed and launched

- [ ] **Step 2: 验证 runtime-config.json 正常生成**

Run: `cat ~/Library/Application\ Support/BoxX/runtime-config.json | python3 -c "import sys,json; c=json.load(sys.stdin); print('route rules:', len(c.get('route',{}).get('rules',[])))"`
Expected: 输出规则数量（如 `route rules: 21`）

- [ ] **Step 3: 验证 Clash API 可达**

Run: `curl -s http://127.0.0.1:9091 | head -1`
Expected: JSON 响应（如 `{"hello":"clash"}`）

- [ ] **Step 4: 验证 DNS flush API**

Run: `curl -s -X POST http://127.0.0.1:9091/cache/dns/flush -w "%{http_code}"` 和 `curl -s -X POST http://127.0.0.1:9091/cache/fakeip/flush -w "%{http_code}"`
Expected: 两个都返回 `204`

- [ ] **Step 5: 延迟测试**

Run: `for i in 1 2 3; do echo "--- $i ---"; curl -o /dev/null -s -w "Total: %{time_total}s | HTTP: %{http_code}\n" https://api.anthropic.com; done`
Expected: 延迟应在 400-500ms 范围（与优化前持平或更好）

- [ ] **Step 6: Commit all**

如果有未提交的修复：
```bash
git add -A
git commit -m "fix: integration fixes for process management refactor"
```

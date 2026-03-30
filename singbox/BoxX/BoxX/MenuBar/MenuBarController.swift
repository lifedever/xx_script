import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let appState: AppState
    private var cachedGroups: [ProxyGroup] = []
    private var cachedMode: String = "rule"
    private var delayResults: [String: Int] = [:]  // node name -> delay ms

    init(appState: AppState) {
        self.appState = appState
        super.init()
        setupStatusItem()
        Task { await fetchAndRebuild() }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        rebuildMenuFromCache()
    }

    func updateIcon() {
        let icon = appState.isRunning ? "shippingbox.fill" : "shippingbox"
        statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "BoxX")
    }

    /// Fetch proxy groups from Clash API, then rebuild menu synchronously
    func fetchAndRebuild() async {
        cachedGroups = (try? await appState.api.getProxies()) ?? []
        cachedMode = (try? await appState.api.getConfig())?.mode ?? "rule"
        rebuildMenuFromCache()
    }

    // Menu about to open: show cached menu immediately, refresh in background for staleness
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            await self.fetchAndRebuild()
        }
    }

    /// Build menu synchronously from cached data — no async, no delay
    private func rebuildMenuFromCache() {
        let menu: NSMenu
        if let existing = statusItem.menu {
            existing.removeAllItems()
            menu = existing
        } else {
            menu = NSMenu()
            menu.delegate = self
            statusItem.menu = menu
        }

        // ── Status header (green dot when running) ──
        let si = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        si.isEnabled = false
        if appState.isRunning {
            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: "BoxX  ", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            str.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.systemGreen,
            ]))
            str.append(NSAttributedString(string: " 运行中", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            si.attributedTitle = str
        } else {
            si.attributedTitle = NSAttributedString(string: "BoxX  ○ 已停止", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        menu.addItem(si)

        // ── Apply config banner ──
        if appState.pendingReload && appState.isRunning {
            let reloadItem = NSMenuItem(title: "", action: #selector(applyConfig), keyEquivalent: "")
            reloadItem.target = self
            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: "⚠️ ", attributes: [.font: NSFont.menuFont(ofSize: 0)]))
            str.append(NSAttributedString(string: "配置已更新，点击应用", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]))
            reloadItem.attributedTitle = str
            menu.addItem(reloadItem)
            menu.addItem(.separator())
        }

        // ── 操作 submenu ──
        let opsMenu = NSMenu()
        if appState.isRunning {
            let stopItem = NSMenuItem(title: "停止", action: #selector(stopSingBox), keyEquivalent: "")
            stopItem.target = self
            opsMenu.addItem(stopItem)
            let restartItem = NSMenuItem(title: "重启", action: #selector(restartSingBox), keyEquivalent: "")
            restartItem.target = self
            opsMenu.addItem(restartItem)
        } else {
            let startItem = NSMenuItem(title: "启动", action: #selector(startSingBox), keyEquivalent: "")
            startItem.target = self
            opsMenu.addItem(startItem)
        }
        let opsItem = NSMenuItem(title: "操作", action: nil, keyEquivalent: "")
        opsItem.submenu = opsMenu
        menu.addItem(opsItem)

        // ── Outbound mode (same group as 操作) ──
        let modeMenu = NSMenu()
        for mode in ["rule", "global", "direct"] {
            let label: String
            switch mode {
            case "rule": label = "规则模式"
            case "global": label = "全局模式"
            case "direct": label = "直连模式"
            default: label = mode
            }
            let item = NSMenuItem(title: label, action: #selector(switchMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = (mode == cachedMode) ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "出站模式", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        menu.addItem(.separator())

        // ── Proxy groups ──
        let selectorGroups = cachedGroups.filter { $0.type == "Selector" }
        let classified = classifyGroups(selectorGroups)

        for group in classified.top {
            menu.addItem(makeGroupMenuItem(group))
        }
        if !classified.top.isEmpty { menu.addItem(.separator()) }

        if !classified.services.isEmpty {
            menu.addItem(makeSectionHeader("服务分流"))
            for group in classified.services { menu.addItem(makeGroupMenuItem(group)) }
            menu.addItem(.separator())
        }

        if !classified.regions.isEmpty {
            menu.addItem(makeSectionHeader("地区节点"))
            for group in classified.regions { menu.addItem(makeGroupMenuItem(group)) }
            menu.addItem(.separator())
        }

        if !classified.subscriptions.isEmpty {
            menu.addItem(makeSectionHeader("订阅分组"))
            for group in classified.subscriptions { menu.addItem(makeGroupMenuItem(group)) }
            menu.addItem(.separator())
        }

        // ── Bottom actions ──
        let updateItem = NSMenuItem(title: "更新订阅", action: nil, keyEquivalent: "")
        let updateSubmenu = NSMenu()

        let updateAllItem = NSMenuItem(title: "全部更新", action: #selector(updateSubscriptions), keyEquivalent: "")
        updateAllItem.target = self
        updateSubmenu.addItem(updateAllItem)

        let subs = SubscriptionsView.loadSubscriptions()
        if !subs.isEmpty {
            updateSubmenu.addItem(.separator())
            for sub in subs {
                let subItem = NSMenuItem(title: sub.name, action: #selector(updateSingleSubscription(_:)), keyEquivalent: "")
                subItem.target = self
                subItem.representedObject = sub
                updateSubmenu.addItem(subItem)
            }
        }

        updateItem.submenu = updateSubmenu
        menu.addItem(updateItem)

        let copyEnvItem = NSMenuItem(title: "复制环境变量", action: #selector(copyProxyEnv), keyEquivalent: "")
        copyEnvItem.target = self
        menu.addItem(copyEnvItem)

        let openConfigItem = NSMenuItem(title: "打开配置目录", action: #selector(openConfigDir), keyEquivalent: "")
        openConfigItem.target = self
        menu.addItem(openConfigItem)

        let monitorItem = NSMenuItem(title: "监控", action: #selector(openMonitor), keyEquivalent: "m")
        monitorItem.target = self
        monitorItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(monitorItem)

        let showWindowItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "m")
        showWindowItem.target = self
        showWindowItem.keyEquivalentModifierMask = [.command]
        menu.addItem(showWindowItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 BoxX", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

    }

    // MARK: - Section Header

    private func makeSectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    // MARK: - Group Menu Item with Custom View

    private func makeGroupMenuItem(_ group: ProxyGroup) -> NSMenuItem {
        let item = NSMenuItem()
        let currentNode = group.now ?? "–"

        let view = ProxyGroupMenuItemView(
            groupName: group.name,
            nodeName: currentNode,
            width: 320,
            height: 22
        )
        item.view = view

        // Create submenu with nodes
        let submenu = NSMenu()

        // Speed test item at top (custom view to prevent menu closing)
        let testItem = NSMenuItem()
        let testView = SpeedTestMenuItemView(groupName: group.name) { [weak self] in
            self?.doTestGroupSpeed(group: group, in: submenu)
        }
        testItem.view = testView
        submenu.addItem(testItem)
        submenu.addItem(.separator())

        for node in group.displayAll {
            let title: String
            if let delay = delayResults[node] {
                title = delay > 0 ? "\(node)  \(delay)ms" : "\(node)  超时"
            } else {
                title = node
            }
            let nodeItem = NSMenuItem(title: "", action: #selector(selectNode(_:)), keyEquivalent: "")
            nodeItem.target = self
            nodeItem.representedObject = ["group": group.name, "node": node] as NSDictionary
            if node == group.now {
                nodeItem.state = .on
            }
            // Color-coded delay
            let attrStr = NSMutableAttributedString(string: node, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            if let delay = delayResults[node] {
                let delayText: String
                let color: NSColor
                if delay <= 0 {
                    delayText = "  超时"
                    color = .systemRed
                } else if delay < 200 {
                    delayText = "  \(delay)ms"
                    color = .systemGreen
                } else if delay < 500 {
                    delayText = "  \(delay)ms"
                    color = .systemOrange
                } else {
                    delayText = "  \(delay)ms"
                    color = .systemRed
                }
                attrStr.append(NSAttributedString(string: delayText, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                    .foregroundColor: color,
                ]))
            }
            nodeItem.attributedTitle = attrStr
            submenu.addItem(nodeItem)
        }
        item.submenu = submenu

        return item
    }

    // MARK: - Classification

    private struct ClassifiedGroups {
        var top: [ProxyGroup] = []
        var services: [ProxyGroup] = []
        var regions: [ProxyGroup] = []
        var subscriptions: [ProxyGroup] = []
    }

    private func classifyGroups(_ groups: [ProxyGroup]) -> ClassifiedGroups {
        // Read region group names from group-patterns.json
        let patterns = appState.configEngine.loadGroupPatterns()
        let regionGroupNames = Set(patterns.keys)

        var result = ClassifiedGroups()
        var classifiedIDs = Set<String>()

        for group in groups {
            if group.name.hasPrefix("📦") {
                result.subscriptions.append(group)
                classifiedIDs.insert(group.id)
            } else if regionGroupNames.contains(group.name) || group.name == "🌐其他" {
                result.regions.append(group)
                classifiedIDs.insert(group.id)
            }
        }

        // Classify remaining by checking if they're service-like (has outbound rule) or general
        let serviceNames: Set<String> = ["OpenAI", "Google", "YouTube", "Netflix", "Disney", "TikTok", "Microsoft", "Notion", "Apple", "Telegram", "Spotify", "Twitter", "GitHub", "Steam", "Twitch", "Claude", "Gemini", "ChatGPT"]
        for group in groups where !classifiedIDs.contains(group.id) {
            if serviceNames.contains(where: { group.name.contains($0) }) {
                result.services.append(group)
                classifiedIDs.insert(group.id)
            }
        }

        for group in groups where !classifiedIDs.contains(group.id) {
            result.top.append(group)
        }

        return result
    }

    // MARK: - Actions

    @objc private func startSingBox() {
        Task {
            do {
                print("[BoxX] Deploying runtime config...")
                try appState.configEngine.deployRuntime()
                let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
                print("[BoxX] Starting sing-box with: \(runtimePath)")
                try await appState.singBoxProcess.start(configPath: runtimePath, mixedPort: appState.configEngine.mixedPort)
                print("[BoxX] sing-box started successfully")
            } catch {
                print("[BoxX] ERROR: \(error)")
                // Show alert as a system notification since main window may not be open
                let alert = NSAlert()
                alert.messageText = "启动失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
            StatusPoller.shared.nudge(appState: appState)
            await fetchAndRebuild()
        }
    }

    @objc private func stopSingBox() {
        Task {
            await appState.singBoxProcess.stop()
            StatusPoller.shared.nudge(appState: appState)
            await fetchAndRebuild()
        }
    }

    @objc private func restartSingBox() {
        Task {
            do {
                try appState.configEngine.deployRuntime()
                let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
                try await appState.singBoxProcess.restart(configPath: runtimePath, mixedPort: appState.configEngine.mixedPort)
            } catch {
                appState.showAlert(error.localizedDescription)
            }
            StatusPoller.shared.nudge(appState: appState)
            await fetchAndRebuild()
        }
    }

    @objc private func switchMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        Task { try? await appState.api.setMode(mode) }
    }

    @objc private func selectNode(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? NSDictionary,
              let groupName = info["group"] as? String,
              let nodeName = info["node"] as? String
        else { return }
        Task {
            try? await appState.api.selectProxy(group: groupName, name: nodeName)
            if let idx = appState.configEngine.config.outbounds.firstIndex(where: {
                if case .selector(let s) = $0, s.tag == groupName { return true }
                return false
            }) {
                if case .selector(var selector) = appState.configEngine.config.outbounds[idx] {
                    selector.`default` = nodeName
                    appState.configEngine.config.outbounds[idx] = .selector(selector)
                    try? appState.configEngine.save(restartRequired: false)
                }
            }
            await fetchAndRebuild()
        }
    }

    private func menuSubLog(_ message: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(time)] \(message)"
        NotificationCenter.default.post(name: .subscriptionLogAppend, object: line)
    }

    @objc private func updateSubscriptions() {
        NotificationCenter.default.post(name: .subscriptionLogStart, object: nil)
        Task {
            let subs = SubscriptionsView.loadSubscriptions()
            menuSubLog("开始更新全部订阅...")
            for sub in subs {
                guard let url = URL(string: sub.url) else {
                    menuSubLog("\(sub.name) URL 无效")
                    continue
                }
                menuSubLog("正在更新: \(sub.name)")
                do {
                    let result = try await appState.subscriptionService.updateSubscription(name: sub.name, url: url)
                    menuSubLog("\(sub.name) 完成, \(result.nodeCount) 个节点")
                } catch {
                    menuSubLog("\(sub.name) 失败: \(error.localizedDescription)")
                    NotificationCenter.default.post(name: .subscriptionUpdateFailed, object: sub)
                }
            }
            menuSubLog("全部更新完成")
        }
    }

    @objc private func updateSingleSubscription(_ sender: NSMenuItem) {
        guard let sub = sender.representedObject as? Subscription,
              let url = URL(string: sub.url) else { return }
        NotificationCenter.default.post(name: .subscriptionLogStart, object: nil)
        Task {
            menuSubLog("开始更新: \(sub.name)")
            do {
                let result = try await appState.subscriptionService.updateSubscription(name: sub.name, url: url)
                menuSubLog("\(sub.name) 完成, \(result.nodeCount) 个节点")
            } catch {
                menuSubLog("\(sub.name) 失败: \(error.localizedDescription)")
                NotificationCenter.default.post(name: .subscriptionUpdateFailed, object: sub)
            }
        }
    }

    @objc private func copyProxyEnv() {
        let inb = appState.configEngine.proxyInbound
        let httpPort = inb.isMixed ? inb.mixedPort : inb.httpPort
        let socksPort = inb.isMixed ? inb.mixedPort : inb.socksPort
        let env = """
        export https_proxy=http://127.0.0.1:\(httpPort)
        export http_proxy=http://127.0.0.1:\(httpPort)
        export all_proxy=socks5://127.0.0.1:\(socksPort)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(env, forType: .string)
    }

    private func doTestGroupSpeed(group: ProxyGroup, in submenu: NSMenu) {
        // Find the SpeedTestMenuItemView to update its state
        let testView = submenu.items.first?.view as? SpeedTestMenuItemView
        testView?.setTesting(true)

        Task {
            for node in group.displayAll {
                do {
                    let delay = try await appState.api.getDelay(name: node)
                    delayResults[node] = delay
                } catch {
                    delayResults[node] = 0
                }
                updateNodeMenuItem(in: submenu, node: node)
            }
            testView?.setTesting(false)
        }
    }

    private func updateNodeMenuItem(in menu: NSMenu, node: String) {
        for menuItem in menu.items {
            guard let info = menuItem.representedObject as? NSDictionary,
                  info["node"] as? String == node else { continue }
            let attrStr = NSMutableAttributedString(string: node, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            if let delay = delayResults[node] {
                let delayText: String
                let color: NSColor
                if delay <= 0 {
                    delayText = "  超时"; color = .systemRed
                } else if delay < 200 {
                    delayText = "  \(delay)ms"; color = .systemGreen
                } else if delay < 500 {
                    delayText = "  \(delay)ms"; color = .systemOrange
                } else {
                    delayText = "  \(delay)ms"; color = .systemRed
                }
                attrStr.append(NSAttributedString(string: delayText, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                    .foregroundColor: color,
                ]))
            }
            menuItem.attributedTitle = attrStr
            break
        }
    }

    @objc private func applyConfig() {
        Task {
            await appState.applyConfig()
            await fetchAndRebuild()
        }
    }

    @objc private func openMonitor() {
        openMonitorWindow()
    }

    @objc private func openConfigDir() {
        NSWorkspace.shared.open(appState.configEngine.baseDir)
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == "BoxX" {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
    }

    @objc private func quitApp() {
        AppDelegate.shared?.shouldReallyQuit = true
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Custom NSView for Surge-style menu item

final class ProxyGroupMenuItemView: NSView {
    private let groupName: String
    private let nodeName: String
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false

    init(groupName: String, nodeName: String, width: CGFloat, height: CGFloat) {
        self.groupName = groupName
        self.nodeName = nodeName
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: frame.width, height: frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.controlAccentColor.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4)
            path.fill()
        }

        let padding: CGFloat = 14
        let arrowSpace: CGFloat = 18
        let font = NSFont.menuFont(ofSize: 0)  // System default menu font
        let textColor = isHighlighted ? NSColor.white : NSColor.labelColor
        let secondaryColor = isHighlighted ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor

        // Left: group name
        let leftAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let leftStr = NSAttributedString(string: groupName, attributes: leftAttrs)
        let leftSize = leftStr.size()
        leftStr.draw(at: NSPoint(x: padding, y: (bounds.height - leftSize.height) / 2))

        // Arrow ❯ (right edge)
        let arrowFont = NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2, weight: .medium)
        let arrowAttrs: [NSAttributedString.Key: Any] = [.font: arrowFont, .foregroundColor: secondaryColor]
        let arrowStr = NSAttributedString(string: "❯", attributes: arrowAttrs)
        let arrowSize = arrowStr.size()
        let arrowX = bounds.width - padding + 2
        arrowStr.draw(at: NSPoint(x: arrowX, y: (bounds.height - arrowSize.height) / 2))

        // Right: current node (right-aligned, flush before arrow)
        let rightAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: secondaryColor]
        let rightStr = NSAttributedString(string: nodeName, attributes: rightAttrs)
        let rightSize = rightStr.size()
        let rightX = arrowX - arrowSpace - rightSize.width + 8
        rightStr.draw(at: NSPoint(x: max(rightX, leftSize.width + padding + 10), y: (bounds.height - rightSize.height) / 2))
    }
}

// MARK: - Speed Test Menu Item View (prevents menu from closing on click)

final class SpeedTestMenuItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var onClick: (() -> Void)?
    private var isTesting = false

    private let icon = NSImageView()

    init(groupName: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 22))

        icon.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 12, y: 3, width: 16, height: 16)
        addSubview(icon)

        label.stringValue = "测速全部"
        label.font = NSFont.menuFont(ofSize: 0)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 32, y: 2)
        addSubview(label)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 32 + label.frame.width + 8, y: 3, width: 16, height: 16)
        spinner.isHidden = true
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTesting(_ testing: Bool) {
        isTesting = testing
        if testing {
            label.stringValue = "测速中..."
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            label.stringValue = "测速全部"
            spinner.isHidden = true
            spinner.stopAnimation(nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isTesting else { return }
        onClick?()
    }

    // Highlight on hover
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isMouseInside {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
            label.textColor = .white
            icon.contentTintColor = .white
        } else {
            label.textColor = .labelColor
            icon.contentTintColor = .secondaryLabelColor
        }
    }

    private var isMouseInside = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true; needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false; needsDisplay = true
    }
}

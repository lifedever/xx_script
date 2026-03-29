import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let appState: AppState
    private var cachedGroups: [ProxyGroup] = []

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
        let menu = NSMenu()
        menu.delegate = self

        // ── Status header (green dot when running) ──
        let si = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        si.isEnabled = false
        if appState.isRunning {
            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: "BoxX  ", attributes: [
                .font: NSFont.menuFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            str.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.systemGreen,
            ]))
            str.append(NSAttributedString(string: " 运行中", attributes: [
                .font: NSFont.menuFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            si.attributedTitle = str
        } else {
            si.attributedTitle = NSAttributedString(string: "BoxX  ○ 已停止", attributes: [
                .font: NSFont.menuFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        menu.addItem(si)
        menu.addItem(.separator())

        // ── Outbound mode ──
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
        let updateItem = NSMenuItem(title: "更新订阅", action: #selector(updateSubscriptions), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let copyEnvItem = NSMenuItem(title: "复制环境变量", action: #selector(copyProxyEnv), keyEquivalent: "")
        copyEnvItem.target = self
        menu.addItem(copyEnvItem)

        let openConfigItem = NSMenuItem(title: "打开配置目录", action: #selector(openConfigDir), keyEquivalent: "")
        openConfigItem.target = self
        menu.addItem(openConfigItem)

        let showWindowItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "m")
        showWindowItem.target = self
        showWindowItem.keyEquivalentModifierMask = [.command]
        menu.addItem(showWindowItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 BoxX", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        statusItem.menu = menu
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
        for node in group.displayAll {
            let nodeItem = NSMenuItem(title: node, action: #selector(selectNode(_:)), keyEquivalent: "")
            nodeItem.target = self
            nodeItem.representedObject = ["group": group.name, "node": node] as NSDictionary
            if node == group.now {
                nodeItem.state = .on
            }
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
        let serviceNames: Set<String> = ["OpenAI", "Google", "YouTube", "Netflix", "Disney", "TikTok", "Microsoft", "Notion", "Apple", "Telegram", "Spotify", "Twitter", "GitHub", "Steam", "Twitch", "Claude", "Gemini", "ChatGPT"]
        let regionPrefixes = ["🇭🇰", "🇨🇳", "🇯🇵", "🇰🇷", "🇸🇬", "🇺🇸", "🇬🇧", "🇩🇪", "🇫🇷", "🇦🇺", "🇨🇦", "🇹🇼", "🌍"]
        let regionNames = ["香港", "日本", "韩国", "新加坡", "美国", "英国", "德国", "法国", "澳大利亚", "加拿大", "台湾", "其他"]

        var result = ClassifiedGroups()
        var classifiedIDs = Set<String>()

        for group in groups {
            if group.name.hasPrefix("📦") {
                result.subscriptions.append(group)
                classifiedIDs.insert(group.id)
            } else if regionPrefixes.contains(where: { group.name.hasPrefix($0) }) || regionNames.contains(where: { group.name.contains($0) }) {
                result.regions.append(group)
                classifiedIDs.insert(group.id)
            } else if serviceNames.contains(where: { group.name.contains($0) }) {
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
                    try? appState.configEngine.save()
                }
            }
            await fetchAndRebuild()
        }
    }

    @objc private func updateSubscriptions() {
        Task {
            let subs = SubscriptionsView.loadSubscriptions()
            for sub in subs {
                guard let url = URL(string: sub.url) else { continue }
                _ = try? await appState.subscriptionService.updateSubscription(name: sub.name, url: url)
            }
        }
    }

    @objc private func copyProxyEnv() {
        let env = """
        export https_proxy=http://127.0.0.1:7890
        export http_proxy=http://127.0.0.1:7890
        export all_proxy=socks5://127.0.0.1:7890
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(env, forType: .string)
    }

    @objc private func openConfigDir() {
        NSWorkspace.shared.open(appState.configEngine.baseDir)
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == "BoxX" {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func quitApp() {
        (NSApp.delegate as? AppDelegate)?.shouldReallyQuit = true
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
        let font = NSFont.menuFont(ofSize: 14)
        let textColor = isHighlighted ? NSColor.white : NSColor.labelColor
        let secondaryColor = isHighlighted ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor

        // Left: group name
        let leftAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let leftStr = NSAttributedString(string: groupName, attributes: leftAttrs)
        let leftSize = leftStr.size()
        leftStr.draw(at: NSPoint(x: padding, y: (bounds.height - leftSize.height) / 2))

        // Arrow ❯ (right edge)
        let arrowFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
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

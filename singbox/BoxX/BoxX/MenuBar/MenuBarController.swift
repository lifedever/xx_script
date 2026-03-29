import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func updateIcon() {
        let icon = appState.isRunning ? "shippingbox.fill" : "shippingbox"
        statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "BoxX")
    }

    // Called when menu is about to open - rebuild with fresh data
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            await self.refreshMenu()
        }
    }

    func refreshMenu() async {
        let menu = NSMenu()
        menu.delegate = self

        // -- Status header --
        let statusTitle = appState.isRunning ? "BoxX  ● 运行中" : "BoxX  ○ 已停止"
        let headerItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // -- Outbound mode --
        let modeMenu = NSMenu()
        var currentMode = "rule"
        if let config = try? await appState.api.getConfig() {
            currentMode = config.mode ?? "rule"
        }
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
            item.representedObject = mode as NSString
            if mode == currentMode {
                item.state = .on
            }
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "出站模式", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        menu.addItem(.separator())

        // -- Proxy groups --
        let groups = (try? await appState.api.getProxies()) ?? []
        let selectorGroups = groups.filter { $0.type == "Selector" }
        let classified = classifyGroups(selectorGroups)

        // Top-level groups
        for group in classified.top {
            menu.addItem(makeGroupMenuItem(group))
        }
        if !classified.top.isEmpty { menu.addItem(.separator()) }

        // Services section
        if !classified.services.isEmpty {
            menu.addItem(makeSectionHeader("服务分流"))
            for group in classified.services {
                menu.addItem(makeGroupMenuItem(group))
            }
            menu.addItem(.separator())
        }

        // Regions section
        if !classified.regions.isEmpty {
            menu.addItem(makeSectionHeader("地区节点"))
            for group in classified.regions {
                menu.addItem(makeGroupMenuItem(group))
            }
            menu.addItem(.separator())
        }

        // Subscriptions section
        if !classified.subscriptions.isEmpty {
            menu.addItem(makeSectionHeader("订阅分组"))
            for group in classified.subscriptions {
                menu.addItem(makeGroupMenuItem(group))
            }
            menu.addItem(.separator())
        }

        // -- Bottom actions --
        let updateItem = NSMenuItem(title: "更新订阅", action: #selector(updateSubscriptions), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

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

    // MARK: - Group Menu Item with Right-Aligned Node Name

    private func makeGroupMenuItem(_ group: ProxyGroup) -> NSMenuItem {
        let item = NSMenuItem()
        let currentNode = group.now ?? "–"

        // Attributed title with right-aligned tab stop (Surge-style)
        let fullText = "\(group.name)\t\(currentNode)"

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .right, location: 280),
        ]

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 14),
            .paragraphStyle: paragraphStyle,
        ]

        let attrStr = NSMutableAttributedString(string: fullText, attributes: attrs)

        // Make the right part (after tab) secondary color
        let tabRange = (fullText as NSString).range(of: "\t")
        if tabRange.location != NSNotFound {
            let rightRange = NSRange(
                location: tabRange.location + 1,
                length: (fullText as NSString).length - tabRange.location - 1
            )
            attrStr.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: rightRange)
        }

        item.attributedTitle = attrStr

        // Submenu with nodes
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
        let serviceNames: Set<String> = [
            "OpenAI", "Google", "YouTube", "Netflix",
            "Disney", "TikTok", "Microsoft", "Notion",
            "Apple", "Telegram", "Spotify", "Twitter",
            "GitHub", "Steam", "Twitch", "Claude",
            "Gemini", "ChatGPT",
        ]
        let regionPrefixes = ["🇭🇰", "🇨🇳", "🇯🇵", "🇰🇷", "🇸🇬", "🇺🇸", "🇬🇧", "🇩🇪", "🇫🇷", "🇦🇺", "🇨🇦", "🇹🇼", "🌍"]
        let regionNames = ["香港", "日本", "韩国", "新加坡", "美国", "英国", "德国", "法国", "澳大利亚", "加拿大", "台湾"]

        var result = ClassifiedGroups()
        var classifiedIDs = Set<String>()

        for group in groups {
            if group.name.hasPrefix("📦") {
                result.subscriptions.append(group)
                classifiedIDs.insert(group.id)
            } else if regionPrefixes.contains(where: { group.name.hasPrefix($0) })
                || regionNames.contains(where: { group.name.contains($0) })
            {
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
        Task {
            try? await appState.api.setMode(mode)
        }
    }

    @objc private func selectNode(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? NSDictionary,
              let groupName = info["group"] as? String,
              let nodeName = info["node"] as? String
        else { return }
        Task {
            try? await appState.api.selectProxy(group: groupName, name: nodeName)
            // Persist to ConfigEngine
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
        // If no window found, try opening via SwiftUI environment
        // The Window scene with id "main" should auto-create when activated
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

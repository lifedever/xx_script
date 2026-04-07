import AppKit
import SwiftUI
import ShadowProxyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = ProxyViewModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "ShadowProxy")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 360)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopover(viewModel: viewModel)
        )

        signal(SIGTERM) { _ in
            try? SystemProxy.disable()
            exit(0)
        }

        viewModel.loadConfig()

        // Close any auto-opened windows (LSUIElement mode)
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
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func updateStatusIcon(running: Bool) {
        if let button = statusItem?.button {
            let config = NSImage.SymbolConfiguration(paletteColors: [running ? .systemGreen : .systemGray])
            button.image = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "ShadowProxy")?
                .withSymbolConfiguration(config)
        }
    }
}

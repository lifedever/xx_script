import SwiftUI
import ShadowProxyCore

@main
struct ShadowProxyApp: App {
    @StateObject private var viewModel = ProxyViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 520, minHeight: 400)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .windowResizability(.contentMinSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: ProxyViewModel?

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up system proxy on any exit (normal quit, force quit via Cmd+Q, etc.)
        try? SystemProxy.disable()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for SIGTERM (kill command) to clean up proxy
        signal(SIGTERM) { _ in
            try? SystemProxy.disable()
            exit(0)
        }
    }
}

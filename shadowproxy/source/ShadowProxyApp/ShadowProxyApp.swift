import SwiftUI
import ShadowProxyCore

@main
struct ShadowProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("ShadowProxy", id: "main") {
            MainWindowView(viewModel: appDelegate.viewModel)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Window("请求查看器", id: "request-viewer") {
            RequestViewerWindow(viewModel: appDelegate.viewModel)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
    }
}

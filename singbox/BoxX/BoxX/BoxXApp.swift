import SwiftUI

@main
struct BoxXApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text("BoxX — sing-box client")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: appState.isRunning ? "network" : "network.slash")
        }

        Window("BoxX", id: "main") {
            Text("BoxX Dashboard")
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}

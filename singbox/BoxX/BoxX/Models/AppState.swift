import SwiftUI

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var isRunning = false
    var isUpdatingSubscription = false
    var errorMessage: String?
    var showError = false

    // v2: core services
    let configEngine: ConfigEngine
    let xpcClient: XPCClient
    let api: ClashAPI
    let subscriptionService: SubscriptionService

    private init() {
        let baseDir = URL(fileURLWithPath: "/Library/Application Support/BoxX")
        configEngine = ConfigEngine(baseDir: baseDir)
        xpcClient = XPCClient()
        api = ClashAPI()
        subscriptionService = SubscriptionService(configEngine: configEngine)

        // Wire ConfigEngine deploy callback to XPC reload
        configEngine.onDeployComplete = { [xpcClient] in
            _ = await xpcClient.reload()
        }
    }

    func showAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}

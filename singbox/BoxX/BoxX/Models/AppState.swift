import SwiftUI

@MainActor
@Observable
final class AppState {
    var isRunning = false
    var pid: Int32 = 0
    var isGenerating = false
    var generateOutput: [String] = []
    var errorMessage: String?
    var showError = false
    var isHelperInstalled = false

    func showAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}

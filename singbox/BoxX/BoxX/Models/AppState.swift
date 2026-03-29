import SwiftUI

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var isRunning = false
    var isGenerating = false
    var errorMessage: String?
    var showError = false

    func showAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}

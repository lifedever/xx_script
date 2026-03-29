import Foundation
import Observation

@Observable
@MainActor
final class SingBoxManager {
    static let shared = SingBoxManager()

    private let helperManager = HelperManager.shared
    private let clashAPI = ClashAPI()

    var isRunning = false
    var pid: Int32 = 0
    var isExternalProcess = false

    func refreshStatus() async {
        // Simple: if Clash API responds, sing-box is running
        let apiReachable = await clashAPI.isReachable()
        if apiReachable {
            isRunning = true
            // We don't know the PID without Helper, that's fine
            isExternalProcess = true
            return
        }
        isRunning = false
        pid = 0
        isExternalProcess = false
    }

    func start(configPath: String) async throws {
        helperManager.disconnect()

        return try await withCheckedThrowingContinuation { continuation in
            guard let helper = helperManager.getProxyWithErrorHandler({ error in
                continuation.resume(throwing: SingBoxError.startFailed(error.localizedDescription))
            }) else {
                continuation.resume(throwing: SingBoxError.helperNotAvailable)
                return
            }
            helper.startSingBox(configPath: configPath) { success, error in
                if success {
                    Task { @MainActor in
                        self.isRunning = true
                        self.isExternalProcess = false
                    }
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SingBoxError.startFailed(error ?? "Unknown error"))
                }
            }
        }
    }

    func stop() async throws {
        helperManager.disconnect()

        return try await withCheckedThrowingContinuation { continuation in
            guard let helper = helperManager.getProxyWithErrorHandler({ error in
                continuation.resume(throwing: SingBoxError.stopFailed(error.localizedDescription))
            }) else {
                continuation.resume(throwing: SingBoxError.helperNotAvailable)
                return
            }
            helper.stopSingBox { success, error in
                if success {
                    Task { @MainActor in
                        self.isRunning = false
                        self.pid = 0
                    }
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SingBoxError.stopFailed(error ?? "Unknown error"))
                }
            }
        }
    }

    /// Stop sing-box regardless of how it was started
    func stopAny() async throws {
        if helperManager.isHelperInstalled {
            do {
                try await stop()
                return
            } catch {
                // Helper failed, fallback to script
            }
        }
        try await stopViaScript()
    }

    private func stopViaScript() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"pkill -x sing-box || true\" with administrator privileges"
        ]
        try process.run()
        process.waitUntilExit()
        isRunning = false
        pid = 0
        isExternalProcess = false
    }

    func restart(configPath: String) async throws {
        try await stopAny()
        try await Task.sleep(for: .seconds(2))
        try await start(configPath: configPath)
    }

}

enum SingBoxError: Error, LocalizedError {
    case helperNotAvailable
    case startFailed(String)
    case stopFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotAvailable: return "Helper not installed or not running"
        case .startFailed(let msg): return "Failed to start: \(msg)"
        case .stopFailed(let msg): return "Failed to stop: \(msg)"
        }
    }
}

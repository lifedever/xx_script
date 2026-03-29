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
    /// true = managed by Helper, false = externally started (e.g. box start)
    var isExternalProcess = false

    func refreshStatus() async {
        // 1. Try Helper first
        let helperResult = await checkViaHelper()
        if helperResult.running {
            isRunning = true
            pid = helperResult.pid
            isExternalProcess = false
            return
        }

        // 2. Fallback: check Clash API directly (covers `box start` scenario)
        let apiReachable = await clashAPI.isReachable()
        if apiReachable {
            isRunning = true
            pid = 0 // unknown PID for external process
            isExternalProcess = true
            return
        }

        // 3. Nothing running
        isRunning = false
        pid = 0
        isExternalProcess = false
    }

    private func checkViaHelper() async -> (running: Bool, pid: Int32) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Int32), Never>) in
            guard let helper = helperManager.getProxy() else {
                continuation.resume(returning: (false, 0))
                return
            }
            helper.getStatus { running, pid in
                continuation.resume(returning: (running, pid))
            }
        }
    }

    func start(configPath: String) async throws {
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
                        await self.refreshStatus()
                    }
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SingBoxError.startFailed(error ?? "Unknown error"))
                }
            }
        }
    }

    func stop() async throws {
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

    func restart(configPath: String) async throws {
        try await stop()
        try await Task.sleep(for: .seconds(1))
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

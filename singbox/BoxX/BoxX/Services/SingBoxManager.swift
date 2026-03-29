import Foundation
import Observation

@Observable
@MainActor
final class SingBoxManager {
    static let shared = SingBoxManager()

    private let helperManager = HelperManager.shared

    var isRunning = false
    var pid: Int32 = 0

    func refreshStatus() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let helper = helperManager.getProxy() else {
                self.isRunning = false
                self.pid = 0
                continuation.resume()
                return
            }
            helper.getStatus { running, pid in
                Task { @MainActor in
                    self.isRunning = running
                    self.pid = pid
                    continuation.resume()
                }
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

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
        // 1. Check Clash API first (fast, always works regardless of how sing-box was started)
        let apiReachable = await clashAPI.isReachable()
        if apiReachable {
            // 2. Try Helper to get PID (with timeout, non-blocking)
            if helperManager.isHelperInstalled {
                let helperResult = await checkViaHelper()
                if helperResult.running {
                    isRunning = true
                    pid = helperResult.pid
                    isExternalProcess = false
                    return
                }
            }
            // API reachable but Helper not available → external process
            isRunning = true
            pid = 0
            isExternalProcess = true
            return
        }

        // 3. Nothing running
        isRunning = false
        pid = 0
        isExternalProcess = false
    }

    private func checkViaHelper() async -> (running: Bool, pid: Int32) {
        // Use withTaskGroup + sleep for a timeout to prevent hanging
        await withTaskGroup(of: (Bool, Int32).self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Int32), Never>) in
                    guard let helper = self.helperManager.getProxyWithErrorHandler({ _ in
                        continuation.resume(returning: (false, 0))
                    }) else {
                        continuation.resume(returning: (false, 0))
                        return
                    }
                    helper.getStatus { running, pid in
                        continuation.resume(returning: (running, pid))
                    }
                }
            }
            // Timeout after 3 seconds
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return (false, 0)
            }
            // Return whichever finishes first
            if let result = await group.next() {
                group.cancelAll()
                return result
            }
            return (false, 0)
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

import Foundation

@MainActor
final class SingBoxManager: ObservableObject {
    static let shared = SingBoxManager()

    private let helperManager = HelperManager.shared
    private let api = ClashAPI()

    @Published var isRunning = false
    @Published var pid: Int32 = 0

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
        guard let helper = helperManager.getProxy() else {
            throw SingBoxError.helperNotAvailable
        }
        return try await withCheckedThrowingContinuation { continuation in
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
        guard let helper = helperManager.getProxy() else {
            throw SingBoxError.helperNotAvailable
        }
        return try await withCheckedThrowingContinuation { continuation in
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

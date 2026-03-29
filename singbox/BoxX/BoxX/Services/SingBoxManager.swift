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
        let apiReachable = await clashAPI.isReachable()
        if apiReachable {
            if helperManager.isHelperInstalled {
                let helperResult = await checkViaHelper()
                if helperResult.running {
                    isRunning = true
                    pid = helperResult.pid
                    isExternalProcess = false
                    return
                }
            }
            isRunning = true
            pid = 0
            isExternalProcess = true
            return
        }
        isRunning = false
        pid = 0
        isExternalProcess = false
    }

    private func checkViaHelper() async -> (running: Bool, pid: Int32) {
        await withTimeout(seconds: 3, defaultValue: (false, 0)) {
            await withCheckedContinuation { (cont: CheckedContinuation<(Bool, Int32), Never>) in
                guard let helper = self.helperManager.getProxyWithErrorHandler({ _ in
                    cont.resume(returning: (false, 0))
                }) else {
                    cont.resume(returning: (false, 0))
                    return
                }
                helper.getStatus { running, pid in
                    cont.resume(returning: (running, pid))
                }
            }
        }
    }

    func start(configPath: String) async throws {
        // Disconnect old XPC connection to ensure fresh connection
        helperManager.disconnect()

        let result: (Bool, String?) = await withTimeout(seconds: 10, defaultValue: (false, "XPC timeout")) {
            await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
                guard let helper = self.helperManager.getProxyWithErrorHandler({ error in
                    cont.resume(returning: (false, error.localizedDescription))
                }) else {
                    cont.resume(returning: (false, "Helper not available"))
                    return
                }
                helper.startSingBox(configPath: configPath) { success, error in
                    cont.resume(returning: (success, error))
                }
            }
        }

        if result.0 {
            isRunning = true
            await refreshStatus()
        } else {
            throw SingBoxError.startFailed(result.1 ?? "Unknown error")
        }
    }

    func stop() async throws {
        helperManager.disconnect()

        let result: (Bool, String?) = await withTimeout(seconds: 10, defaultValue: (false, "XPC timeout")) {
            await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
                guard let helper = self.helperManager.getProxyWithErrorHandler({ error in
                    cont.resume(returning: (false, error.localizedDescription))
                }) else {
                    cont.resume(returning: (false, "Helper not available"))
                    return
                }
                helper.stopSingBox { success, error in
                    cont.resume(returning: (success, error))
                }
            }
        }

        if result.0 {
            isRunning = false
            pid = 0
        } else {
            throw SingBoxError.stopFailed(result.1 ?? "Unknown error")
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

    /// Run an async operation with a timeout
    private func withTimeout<T: Sendable>(seconds: Int, defaultValue: T, operation: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return defaultValue
            }
            let result = await group.next() ?? defaultValue
            group.cancelAll()
            return result
        }
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

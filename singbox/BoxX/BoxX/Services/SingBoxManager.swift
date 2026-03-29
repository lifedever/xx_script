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
        // Use osascript to run sing-box with admin privileges
        // Same as `box start` — reads config directly, no permission issues
        let singBoxPath = HelperConstants.singBoxPath
        let script = """
        do shell script "\(singBoxPath) run -c \(configPath) &>/dev/null &" with administrator privileges
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw SingBoxError.startFailed("osascript exited with code \(process.terminationStatus)")
        }

        // Wait for sing-box to be ready
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(200))
            if await clashAPI.isReachable() {
                isRunning = true
                isExternalProcess = false
                return
            }
        }
        throw SingBoxError.startFailed("sing-box started but Clash API not reachable after 6 seconds")
    }

    /// Stop sing-box — uses osascript sudo pkill (same as box stop)
    func stopAny() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"pkill -x sing-box || true\" with administrator privileges"
        ]
        try process.run()
        process.waitUntilExit()

        // Wait for process to actually die
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(200))
            if !(await clashAPI.isReachable()) {
                break
            }
        }
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

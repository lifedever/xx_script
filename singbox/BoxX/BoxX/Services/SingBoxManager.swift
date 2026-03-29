import Foundation
import Observation

@Observable
@MainActor
final class SingBoxManager {
    static let shared = SingBoxManager()

    private let clashAPI = ClashAPI()

    private var boxScript: String {
        let scriptDir = UserDefaults.standard.string(forKey: "scriptDir")
            ?? (NSHomeDirectory() + "/Documents/Dev/myspace/xx_script/singbox")
        return scriptDir + "/box.sh"
    }

    var isRunning = false

    func refreshStatus() async {
        isRunning = await clashAPI.isReachable()
    }

    /// Start sing-box — calls `box.sh start` via sudo
    func start(configPath: String) async throws {
        try await runSudo("\(boxScript) start")
        try await waitForAPI(timeout: 30)
    }

    /// Stop sing-box — calls `box.sh stop` via sudo
    func stop() async throws {
        try await runSudo("\(boxScript) stop")
        // Wait for it to actually stop
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(300))
            if !(await clashAPI.isReachable()) { break }
        }
        isRunning = false
    }

    /// Restart sing-box — calls `box.sh fix` (stop + flush DNS + start)
    func restart(configPath: String) async throws {
        try await runSudo("\(boxScript) fix")
        try await waitForAPI(timeout: 30)
    }

    private func waitForAPI(timeout: Int) async throws {
        let attempts = timeout * 2  // check every 500ms
        for _ in 0..<attempts {
            try await Task.sleep(for: .milliseconds(500))
            if await clashAPI.isReachable() {
                isRunning = true
                return
            }
        }
        // Even if timeout, check once more — it might just be slow
        if await clashAPI.isReachable() {
            isRunning = true
            return
        }
        throw SingBoxError.startFailed("Clash API not reachable after \(timeout) seconds")
    }

    private func runSudo(_ command: String) async throws {
        let script = "do shell script \"\(command)\" with administrator privileges"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: SingBoxError.startFailed("Authorization cancelled or failed"))
                    } else {
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum SingBoxError: Error, LocalizedError {
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .startFailed(let msg): return msg
        }
    }
}

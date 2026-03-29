import Foundation
import Observation

/// sing-box binary path
private let singBoxPath = "/opt/homebrew/bin/sing-box"

@Observable
@MainActor
final class SingBoxManager {
    static let shared = SingBoxManager()

    private let clashAPI = ClashAPI()

    var isRunning = false

    /// Check if sing-box is running by probing the Clash API
    func refreshStatus() async {
        isRunning = await clashAPI.isReachable()
    }

    /// Start sing-box with admin privileges (single password prompt)
    func start(configPath: String) async throws {
        let script = """
        do shell script "dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null; \(singBoxPath) run -c \(configPath) &>/dev/null &" with administrator privileges
        """
        try runOsascript(script)

        // Wait for Clash API to become reachable
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(200))
            if await clashAPI.isReachable() {
                isRunning = true
                return
            }
        }
        throw SingBoxError.startFailed("Clash API not reachable after 6 seconds")
    }

    /// Stop sing-box with admin privileges (single password prompt)
    func stop() async throws {
        let script = """
        do shell script "pkill -x sing-box || true; dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null" with administrator privileges
        """
        try runOsascript(script)

        // Wait for process to die
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(200))
            if !(await clashAPI.isReachable()) { break }
        }
        isRunning = false
    }

    /// Restart sing-box — single password prompt, includes DNS flush
    func restart(configPath: String) async throws {
        let script = """
        do shell script "pkill -x sing-box || true; sleep 2; dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null; \(singBoxPath) run -c \(configPath) &>/dev/null &" with administrator privileges
        """
        try runOsascript(script)

        // Wait for Clash API
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(200))
            if await clashAPI.isReachable() {
                isRunning = true
                return
            }
        }
        throw SingBoxError.startFailed("Clash API not reachable after restart")
    }

    private func runOsascript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw SingBoxError.startFailed("Authorization cancelled or failed")
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

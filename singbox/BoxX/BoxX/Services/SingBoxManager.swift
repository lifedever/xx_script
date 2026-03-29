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
        // Copy config + local rules to /tmp/boxx/ so the root Helper can read them
        // (macOS privacy protection blocks root from reading ~/Documents)
        let tmpDir = "/tmp/boxx"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let srcDir = (configPath as NSString).deletingLastPathComponent
        let tmpConfig = tmpDir + "/config.json"

        // Read and rewrite config, replacing local rule paths
        let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        var configStr = String(data: configData, encoding: .utf8) ?? ""

        // Copy local rule JSON files and update paths in config
        let rulesDir = srcDir + "/rules"
        if FileManager.default.fileExists(atPath: rulesDir) {
            let tmpRules = tmpDir + "/rules"
            try? FileManager.default.createDirectory(atPath: tmpRules, withIntermediateDirectories: true)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: rulesDir) {
                for file in files {
                    let src = rulesDir + "/" + file
                    let dst = tmpRules + "/" + file
                    try? FileManager.default.removeItem(atPath: dst)
                    try? FileManager.default.copyItem(atPath: src, toPath: dst)
                    // Replace path references in config
                    configStr = configStr.replacingOccurrences(of: src, with: dst)
                }
            }
        }

        // Also update cache.db path
        let tmpCache = tmpDir + "/cache.db"
        let srcCache = srcDir + "/cache.db"
        if configStr.contains(srcCache) {
            // Copy existing cache if available
            try? FileManager.default.removeItem(atPath: tmpCache)
            try? FileManager.default.copyItem(atPath: srcCache, toPath: tmpCache)
            configStr = configStr.replacingOccurrences(of: srcCache, with: tmpCache)
        }

        try configStr.write(toFile: tmpConfig, atomically: true, encoding: .utf8)

        helperManager.disconnect()

        return try await withCheckedThrowingContinuation { continuation in
            guard let helper = helperManager.getProxyWithErrorHandler({ error in
                continuation.resume(throwing: SingBoxError.startFailed(error.localizedDescription))
            }) else {
                continuation.resume(throwing: SingBoxError.helperNotAvailable)
                return
            }
            helper.startSingBox(configPath: tmpConfig) { success, error in
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

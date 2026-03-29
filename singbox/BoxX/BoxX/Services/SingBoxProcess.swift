// BoxX/Services/SingBoxProcess.swift
import Foundation

@MainActor
@Observable
class SingBoxProcess {
    var isRunning: Bool = false
    private let singBoxPath = "/opt/homebrew/bin/sing-box"

    /// Start sing-box with admin privileges (for TUN). Runs async to avoid blocking UI.
    func start(configPath: String) async throws {
        guard FileManager.default.fileExists(atPath: singBoxPath) else {
            throw SingBoxError.notInstalled
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw SingBoxError.startFailed("配置文件不存在: \(configPath)")
        }

        // Kill existing on background thread
        await runOnBackground { self.killExistingSync() }
        await runOnBackground { self.waitForPortReleaseSync() }

        // Start via osascript on background thread
        // Escape paths for shell: replace ' with '\''
        let sbPath = singBoxPath
        let escapedConfigPath = configPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedConfigDir = URL(fileURLWithPath: configPath).deletingLastPathComponent().path
            .replacingOccurrences(of: "'", with: "'\\''")

        // Write a temp launcher script to avoid shell quoting issues in osascript
        let launcherScript = """
        #!/bin/bash
        cd '\(escapedConfigDir)'
        '\(sbPath)' run -c '\(escapedConfigPath)' &>/dev/null &
        echo $!
        """
        let launcherPath = "/tmp/boxx-launcher.sh"
        try launcherScript.write(toFile: launcherPath, atomically: true, encoding: .utf8)
        FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath)

        print("[BoxX] Starting sing-box with admin privileges...")

        let exitCode = await runOnBackground { () -> Int32 in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "do shell script \"/tmp/boxx-launcher.sh\" with administrator privileges"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        }

        if exitCode != 0 {
            throw SingBoxError.startFailed("授权被取消")
        }

        // Wait for Clash API on background thread
        let ready = await runOnBackground { () -> Bool in
            for _ in 0..<30 {
                if self.checkClashAPISync() { return true }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return false
        }

        if ready {
            isRunning = true
            print("[BoxX] sing-box started ✅")
        } else if await runOnBackground({ self.findSingBoxPID() }) != nil {
            isRunning = true
            print("[BoxX] sing-box running (API slow)")
        } else {
            throw SingBoxError.startFailed("sing-box 启动后退出，请检查配置")
        }
    }

    /// Stop sing-box
    func stop() async {
        print("[BoxX] Stopping sing-box...")
        await runOnBackground {
            // Try user-level kill first (no password prompt)
            self.killExistingSync()
            Thread.sleep(forTimeInterval: 1)

            // If still running (root process), use osascript
            if self.findSingBoxPID() != nil {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", "do shell script \"pkill -x sing-box\" with administrator privileges"]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
            }
            self.waitForPortReleaseSync()
        }
        isRunning = false
        print("[BoxX] Stopped ✅")
    }

    /// Restart
    func restart(configPath: String) async throws {
        await stop()
        try await start(configPath: configPath)
    }

    /// Check if running
    func refreshStatus() async -> Bool {
        let reachable = await runOnBackground { self.checkClashAPISync() }
        isRunning = reachable
        return reachable
    }

    /// Flush DNS
    func flushDNS() {
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush.arguments = ["-flushcache"]
        flush.standardOutput = FileHandle.nullDevice
        flush.standardError = FileHandle.nullDevice
        try? flush.run()
        flush.waitUntilExit()
    }

    // MARK: - Background helpers

    private func runOnBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let result = work()
                cont.resume(returning: result)
            }
        }
    }

    // MARK: - Sync helpers (run on background thread only)

    private nonisolated func findSingBoxPID() -> Int32? {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "sing-box"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              let pid = Int32(output.components(separatedBy: "\n").first ?? "") else {
            return nil
        }
        return pid
    }

    private nonisolated func killExistingSync() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-x", "sing-box"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private nonisolated func waitForPortReleaseSync() {
        for _ in 0..<30 {
            if !isPortInUse(7890) && !isPortInUse(9091) { return }
            usleep(200_000)
        }
    }

    private nonisolated func isPortInUse(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var optval: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0
    }

    private nonisolated func checkClashAPISync() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:9091") else { return false }
        let request = URLRequest(url: url, timeoutInterval: 1)
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { success = true }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return success
    }
}

enum SingBoxError: Error, LocalizedError {
    case notInstalled
    case startFailed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "sing-box 未安装，请运行: brew install sing-box"
        case .startFailed(let msg): return "启动失败: \(msg)"
        }
    }
}

// BoxX/Services/SingBoxProcess.swift
import Foundation

@MainActor
@Observable
class SingBoxProcess {
    private var process: Process?
    var isRunning: Bool = false

    private let singBoxPath = "/opt/homebrew/bin/sing-box"

    /// Start sing-box with the given config
    func start(configPath: String) throws {
        guard FileManager.default.fileExists(atPath: singBoxPath) else {
            throw SingBoxError.notInstalled
        }

        // Kill any existing sing-box first
        killExisting()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: singBoxPath)
        proc.arguments = ["run", "-c", configPath]
        proc.currentDirectoryURL = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
            }
        }

        try proc.run()
        process = proc
        isRunning = true
    }

    /// Stop sing-box
    func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            // Wait up to 3 seconds for graceful shutdown
            DispatchQueue.global().async {
                for _ in 0..<30 {
                    if !proc.isRunning { return }
                    usleep(100_000)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        process = nil
        // Also kill any orphan sing-box processes
        killExisting()
        isRunning = false
    }

    /// Restart with new config
    func restart(configPath: String) throws {
        stop()
        // Wait for ports to release
        Thread.sleep(forTimeInterval: 1)
        try start(configPath: configPath)
    }

    /// Check if sing-box is running (managed process or orphan)
    func refreshStatus() async -> Bool {
        if let proc = process, proc.isRunning {
            isRunning = true
            return true
        }
        // Check orphan via Clash API
        let reachable = await checkClashAPI()
        isRunning = reachable
        return reachable
    }

    /// Flush DNS cache
    func flushDNS() {
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush.arguments = ["-flushcache"]
        flush.standardOutput = FileHandle.nullDevice
        flush.standardError = FileHandle.nullDevice
        try? flush.run()
        flush.waitUntilExit()
    }

    private func killExisting() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-x", "sing-box"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func checkClashAPI() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "http://127.0.0.1:9091") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode != nil
        } catch {
            return false
        }
    }
}

enum SingBoxError: Error, LocalizedError {
    case notInstalled
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "sing-box not found at /opt/homebrew/bin/sing-box"
        case .startFailed(let msg): return "Failed to start: \(msg)"
        }
    }
}

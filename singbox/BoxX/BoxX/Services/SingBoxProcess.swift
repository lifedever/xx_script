// BoxX/Services/SingBoxProcess.swift
import Foundation

@MainActor
@Observable
class SingBoxProcess {
    private var process: Process?
    var isRunning: Bool = false

    private let singBoxPath = "/opt/homebrew/bin/sing-box"

    /// Start sing-box with the given config. Waits for Clash API to be ready.
    func start(configPath: String) throws {
        guard FileManager.default.fileExists(atPath: singBoxPath) else {
            throw SingBoxError.notInstalled
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw SingBoxError.startFailed("配置文件不存在: \(configPath)")
        }

        // Kill any existing sing-box first
        killExisting()
        // Wait for ports to release
        waitForPortRelease()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: singBoxPath)
        proc.arguments = ["run", "-c", configPath]
        proc.currentDirectoryURL = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardOutput = FileHandle.nullDevice

        // Capture stderr for error reporting
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
            }
        }

        try proc.run()
        process = proc

        // Wait up to 15 seconds for sing-box to start (it downloads rule sets on first run)
        print("[BoxX] sing-box process started (pid \(proc.processIdentifier)), waiting for Clash API...")
        var ready = false
        for i in 0..<30 {
            // Check if process died
            if !proc.isRunning {
                let stderrData = stderrPipe.fileHandleForReading.availableData
                let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                let lastLines = stderrStr.components(separatedBy: "\n")
                    .filter { $0.contains("FATAL") || $0.contains("ERROR") || $0.contains("error") }
                    .suffix(3)
                    .joined(separator: "\n")
                let errorMsg = lastLines.isEmpty ? "sing-box 进程退出 (code \(proc.terminationStatus))" : lastLines
                process = nil
                throw SingBoxError.startFailed(errorMsg)
            }

            // Check Clash API
            if checkClashAPISync() {
                ready = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        if ready {
            isRunning = true
            print("[BoxX] sing-box is ready!")
        } else if proc.isRunning {
            // Process is running but API not ready yet — might still be downloading rule sets
            // Consider it running anyway
            isRunning = true
            print("[BoxX] sing-box process running but API slow to respond, marking as running")
        } else {
            let stderrData = stderrPipe.fileHandleForReading.availableData
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            process = nil
            throw SingBoxError.startFailed(stderrStr)
        }
    }

    /// Stop sing-box
    func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            for _ in 0..<30 {
                if !proc.isRunning { break }
                usleep(100_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                usleep(500_000)
            }
        }
        process = nil
        killExisting()
        isRunning = false
    }

    /// Restart with new config
    func restart(configPath: String) throws {
        stop()
        waitForPortRelease()
        try start(configPath: configPath)
    }

    /// Check if sing-box is running
    func refreshStatus() async -> Bool {
        if let proc = process, proc.isRunning {
            isRunning = true
            return true
        }
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

    // MARK: - Private

    private func killExisting() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-x", "sing-box"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func waitForPortRelease() {
        for _ in 0..<30 {
            if !isPortInUse(7890) && !isPortInUse(9091) { return }
            usleep(200_000)
        }
    }

    private func isPortInUse(_ port: UInt16) -> Bool {
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

    /// Synchronous Clash API check (for use in start wait loop)
    private func checkClashAPISync() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:9091") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1)
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                success = true
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return success
    }

    /// Async Clash API check
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
        case .notInstalled: return "sing-box 未安装，请运行: brew install sing-box"
        case .startFailed(let msg): return "启动失败: \(msg)"
        }
    }
}

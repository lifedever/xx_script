// BoxX/Services/SingBoxProcess.swift
import Foundation
import ServiceManagement

@MainActor
@Observable
class SingBoxProcess {
    var isRunning: Bool = false
    private let xpcClient = XPCClient()
    private var useXPC = false

    private let singBoxPath = "/opt/homebrew/bin/sing-box"

    /// Register XPC Helper on first launch. Call once at app startup.
    func registerHelper() {
        Task {
            do {
                try await xpcClient.register()
                useXPC = true
                print("[BoxX] Helper registered via SMAppService ✅")
            } catch {
                useXPC = false
                print("[BoxX] Helper registration failed: \(error). Using osascript fallback.")
            }
        }
    }

    /// Start sing-box. Uses XPC Helper if available, otherwise osascript.
    func start(configPath: String) throws {
        guard FileManager.default.fileExists(atPath: singBoxPath) else {
            throw SingBoxError.notInstalled
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw SingBoxError.startFailed("配置文件不存在: \(configPath)")
        }

        killExisting()
        waitForPortRelease()

        if useXPC {
            try startViaXPC(configPath: configPath)
        } else {
            try startViaOsascript(configPath: configPath)
        }
    }

    /// Stop sing-box
    func stop() {
        if useXPC {
            Task {
                _ = await xpcClient.stop()
                isRunning = false
                print("[BoxX] Stopped via XPC")
            }
        } else {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "do shell script \"pkill -x sing-box\" with administrator privileges"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            isRunning = false
            print("[BoxX] Stopped via osascript")
        }
        waitForPortRelease()
    }

    /// Restart with new config
    func restart(configPath: String) throws {
        stop()
        try start(configPath: configPath)
    }

    /// Reload config (SIGHUP) — only works with XPC Helper
    func reload() {
        if useXPC {
            Task { _ = await xpcClient.reload() }
        }
    }

    /// Check if sing-box is running
    func refreshStatus() async -> Bool {
        if useXPC {
            let status = await xpcClient.getStatus()
            isRunning = status.running
            return status.running
        }
        // Fallback: check via Clash API
        let reachable = await checkClashAPI()
        isRunning = reachable
        return reachable
    }

    /// Flush DNS cache
    func flushDNS() {
        if useXPC {
            Task { _ = await xpcClient.flushDNS() }
        } else {
            let flush = Process()
            flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
            flush.arguments = ["-flushcache"]
            flush.standardOutput = FileHandle.nullDevice
            flush.standardError = FileHandle.nullDevice
            try? flush.run()
            flush.waitUntilExit()
        }
    }

    // MARK: - XPC Start

    private func startViaXPC(configPath: String) throws {
        print("[BoxX] Starting via XPC Helper...")
        let semaphore = DispatchSemaphore(value: 0)
        var result: (success: Bool, error: String?) = (false, nil)

        Task {
            result = await xpcClient.start(configPath: configPath)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)

        if !result.success {
            throw SingBoxError.startFailed(result.error ?? "XPC Helper 启动失败")
        }

        waitForClashAPI()
        isRunning = true
        print("[BoxX] Started via XPC Helper ✅")
    }

    // MARK: - osascript Start (fallback)

    private func startViaOsascript(configPath: String) throws {
        let configDir = URL(fileURLWithPath: configPath).deletingLastPathComponent().path
        let shellCmd = "cd '\(configDir)' && '\(singBoxPath)' run -c '\(configPath)' &>/dev/null &"

        print("[BoxX] Starting via osascript (admin privileges)...")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "do shell script \"\(shellCmd)\" with administrator privileges"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            throw SingBoxError.startFailed("授权被取消或失败")
        }

        waitForClashAPI()

        if findSingBoxPID() != nil {
            isRunning = true
            print("[BoxX] Started via osascript ✅")
        } else {
            throw SingBoxError.startFailed("sing-box 启动后立即退出，请检查配置")
        }
    }

    // MARK: - Helpers

    private func waitForClashAPI() {
        print("[BoxX] Waiting for Clash API...")
        for _ in 0..<30 {
            if checkClashAPISync() { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func findSingBoxPID() -> Int32? {
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

    private func killExisting() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-x", "sing-box"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
        if findSingBoxPID() != nil { usleep(500_000) }
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

    private func checkClashAPISync() -> Bool {
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

    private func checkClashAPI() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "http://127.0.0.1:9091") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode != nil
        } catch { return false }
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

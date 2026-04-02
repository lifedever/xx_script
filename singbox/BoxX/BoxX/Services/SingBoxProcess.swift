// BoxX/Services/SingBoxProcess.swift
import Foundation
import AppKit

@MainActor
@Observable
class SingBoxProcess {
    var isRunning: Bool = false
    var progressMessage: String?

    // MARK: - XPC Connection

    nonisolated private func connectToHelper() -> HelperProtocol? {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()
        return connection.remoteObjectProxyWithErrorHandler { error in
            print("[BoxX] XPC proxy error: \(error)")
        } as? HelperProtocol
    }

    // MARK: - Start

    func start(configPath: String, mixedPort: Int = 7890) async throws {
        if await refreshStatus() {
            print("[BoxX] sing-box already running, skipping start")
            return
        }

        progressMessage = "正在启动 sing-box..."
        print("[BoxX] Starting sing-box via Helper...")

        guard let helper = connectToHelper() else {
            progressMessage = nil
            throw SingBoxError.startFailed("无法连接 Helper，请在设置中重装 Helper")
        }

        let (success, error) = await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
            helper.startSingBox(configPath: configPath) { ok, err in
                cont.resume(returning: (ok, err))
            }
        }

        guard success else {
            progressMessage = nil
            throw SingBoxError.startFailed(error ?? "未知错误")
        }

        progressMessage = "正在等待 sing-box 就绪..."

        // Wait for Clash API (up to 60s for first-time rule-set downloads)
        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                for _ in 0..<120 {
                    if self.checkClashAPISync() { cont.resume(returning: true); return }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                cont.resume(returning: false)
            }
        }

        if ready {
            isRunning = true
            progressMessage = nil
            print("[BoxX] sing-box started via Helper ✅")
        } else {
            // Check if process is at least running (API might be slow)
            let (running, _) = await getHelperStatus()
            if running {
                isRunning = true
                progressMessage = nil
                print("[BoxX] sing-box running (API slow)")
            } else {
                progressMessage = nil
                throw SingBoxError.startFailed("sing-box 启动后退出，请检查配置")
            }
        }

        // Wait for TUN route table to stabilize, then flush DNS
        if isRunning {
            try? await Task.sleep(for: .seconds(2))
            flushDNS()
            try? await Task.sleep(for: .seconds(1))
            flushDNS()
        }
    }

    // MARK: - Stop

    func stop() async {
        print("[BoxX] Stopping sing-box...")
        guard let helper = connectToHelper() else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            helper.stopSingBox { _, _ in
                cont.resume()
            }
        }
        isRunning = false
        print("[BoxX] Stopped ✅")
    }

    // MARK: - Restart

    func restart(configPath: String, mixedPort: Int = 7890) async throws {
        print("[BoxX] Restarting sing-box...")
        await stop()
        try await start(configPath: configPath, mixedPort: mixedPort)
    }

    // MARK: - Hot Reload (SIGHUP)

    func reload() async {
        guard let helper = connectToHelper() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            helper.reloadSingBox { _, _ in
                cont.resume()
            }
        }
        print("[BoxX] Config reloaded via SIGHUP")
    }

    // MARK: - Status

    func refreshStatus() async -> Bool {
        // Try XPC Helper first
        let (running, _) = await getHelperStatus()
        if running {
            isRunning = true
            return true
        }
        // Fallback: check Clash API directly (Helper may not be updated yet)
        let reachable = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                cont.resume(returning: self.checkClashAPISync())
            }
        }
        isRunning = reachable
        return reachable
    }

    private func getHelperStatus() async -> (Bool, Int32) {
        guard let helper = connectToHelper() else { return (false, 0) }
        return await withCheckedContinuation { (cont: CheckedContinuation<(Bool, Int32), Never>) in
            helper.getStatus { running, pid in
                cont.resume(returning: (running, pid))
            }
        }
    }

    // MARK: - Watch Process Exit (for StatusPoller)

    func watchProcessExit() async -> (Bool, Int32) {
        guard let helper = connectToHelper() else { return (false, 0) }
        return await withCheckedContinuation { (cont: CheckedContinuation<(Bool, Int32), Never>) in
            helper.watchProcessExit { wasRunning, exitCode in
                cont.resume(returning: (wasRunning, exitCode))
            }
        }
    }

    // MARK: - DNS

    func flushDNS() {
        guard let helper = connectToHelper() else {
            // Fallback to local flush (non-root, partial)
            let flush = Process()
            flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
            flush.arguments = ["-flushcache"]
            flush.standardOutput = FileHandle.nullDevice
            flush.standardError = FileHandle.nullDevice
            try? flush.run()
            flush.waitUntilExit()
            return
        }
        helper.flushDNS { _ in }
    }

    // MARK: - Legacy Migration

    func migrateLegacyDaemon() async {
        let legacyPlist = "/Library/LaunchDaemons/com.boxx.singbox.plist"
        guard FileManager.default.fileExists(atPath: legacyPlist) else { return }
        print("[BoxX] Found legacy launchd daemon, migrating...")

        guard let helper = connectToHelper() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            helper.removeLegacyDaemon { _ in
                cont.resume()
            }
        }
        print("[BoxX] Legacy daemon removed ✅")
    }

    // MARK: - Clash API check (for startup readiness)

    private nonisolated func checkClashAPISync() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:9091") else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let request = URLRequest(url: url, timeoutInterval: 2)
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        let task = session.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { success = true }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3)
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

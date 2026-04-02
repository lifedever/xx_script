// BoxX/Services/SingBoxProcess.swift
import Foundation
import AppKit

@MainActor
@Observable
class SingBoxProcess {
    var isRunning: Bool = false
    var progressMessage: String?

    // MARK: - XPC Connection

    private nonisolated(unsafe) static var _connection: NSXPCConnection?
    private nonisolated(unsafe) static var connectionLock = NSLock()

    nonisolated private func connectToHelper() -> HelperProtocol? {
        Self.connectionLock.lock()
        defer { Self.connectionLock.unlock() }

        if let existing = Self._connection {
            return existing.remoteObjectProxyWithErrorHandler { error in
                print("[BoxX] XPC proxy error: \(error)")
                Self.connectionLock.lock()
                Self._connection?.invalidate()
                Self._connection = nil
                Self.connectionLock.unlock()
            } as? HelperProtocol
        }

        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.invalidationHandler = {
            Self.connectionLock.lock()
            Self._connection = nil
            Self.connectionLock.unlock()
        }
        connection.resume()
        Self._connection = connection
        return connection.remoteObjectProxyWithErrorHandler { error in
            print("[BoxX] XPC proxy error: \(error)")
            Self.connectionLock.lock()
            Self._connection?.invalidate()
            Self._connection = nil
            Self.connectionLock.unlock()
        } as? HelperProtocol
    }

    // MARK: - Version Check

    /// Query sing-box version via Helper and validate compatibility
    func checkSingBoxVersion() async throws -> String {
        guard let helper = connectToHelper() else {
            throw SingBoxError.startFailed("无法连接 Helper，请在设置中重装 Helper")
        }

        let version: String? = await withCheckedContinuation { cont in
            var replied = false
            let lock = NSLock()

            helper.getSingBoxVersion { ver in
                lock.lock(); defer { lock.unlock() }
                if !replied { replied = true; cont.resume(returning: ver) }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                lock.lock(); defer { lock.unlock() }
                if !replied { replied = true; cont.resume(returning: nil) }
            }
        }

        guard let version else {
            throw SingBoxError.startFailed("未找到 sing-box，请先安装: brew install sing-box")
        }

        if !Self.isVersionCompatible(version, minimum: HelperConstants.minimumSingBoxVersion) {
            throw SingBoxError.startFailed(
                "sing-box 版本过低: \(version)，最低要求 \(HelperConstants.minimumSingBoxVersion)。请执行: brew upgrade sing-box"
            )
        }

        return version
    }

    /// Compare semantic version strings (e.g. "1.12.0" >= "1.12.0")
    nonisolated static func isVersionCompatible(_ current: String, minimum: String) -> Bool {
        let parse: (String) -> [Int] = { str in
            str.components(separatedBy: ".").compactMap { Int($0) }
        }
        let cur = parse(current)
        let min = parse(minimum)
        for i in 0..<max(cur.count, min.count) {
            let c = i < cur.count ? cur[i] : 0
            let m = i < min.count ? min[i] : 0
            if c > m { return true }
            if c < m { return false }
        }
        return true // equal
    }

    // MARK: - Start

    func start(configPath: String, mixedPort: Int = 7890) async throws {
        if await refreshStatus() {
            print("[BoxX] sing-box already running, skipping start")
            return
        }

        progressMessage = "正在检查 sing-box 版本..."
        let version = try await checkSingBoxVersion()
        print("[BoxX] sing-box version: \(version)")

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
            var replied = false
            let lock = NSLock()

            helper.stopSingBox { _, _ in
                lock.lock(); defer { lock.unlock() }
                if !replied { replied = true; cont.resume() }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                lock.lock(); defer { lock.unlock() }
                if !replied { replied = true; cont.resume() }
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
        return await withCheckedContinuation { cont in
            var replied = false
            let lock = NSLock()

            helper.getStatus { running, pid in
                lock.lock(); defer { lock.unlock() }
                if !replied { replied = true; cont.resume(returning: (running, pid)) }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                lock.lock(); defer { lock.unlock() }
                if !replied { replied = true; cont.resume(returning: (false, 0)) }
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

    // MARK: - Helper Installation

    /// Check if Helper binary and launchd plist are installed on disk
    nonisolated func isHelperInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Library/PrivilegedHelperTools/com.boxx.helper")
            && fm.fileExists(atPath: "/Library/LaunchDaemons/com.boxx.helper.plist")
    }

    /// Check if Helper daemon is actually responding via XPC (3s timeout)
    nonisolated func isHelperResponding() async -> Bool {
        await withCheckedContinuation { cont in
            let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.resume()

            var replied = false
            let lock = NSLock()

            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in
                lock.lock(); defer { lock.unlock() }
                if !replied { replied = true; cont.resume(returning: false) }
            }) as? HelperProtocol else {
                cont.resume(returning: false)
                return
            }

            helper.getStatus { _, _ in
                lock.lock(); defer { lock.unlock() }
                if !replied { replied = true; cont.resume(returning: true) }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                lock.lock(); defer { lock.unlock() }
                if !replied { replied = true; cont.resume(returning: false) }
            }
        }
    }

    /// Install or upgrade Helper via osascript (admin prompt)
    func installHelper() async -> Bool {
        let appPath = Bundle.main.bundlePath
        let helperSrc = "\(appPath)/Contents/Library/LaunchDaemons/BoxXHelper"

        guard FileManager.default.fileExists(atPath: helperSrc) else {
            print("[BoxX] Helper binary not found in app bundle: \(helperSrc)")
            return false
        }

        // Write install script to temp file (avoids shell escaping nightmares)
        let scriptPath = "/tmp/boxx-install-helper.sh"
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.boxx.helper</string>
            <key>ProgramArguments</key>
            <array>
                <string>/Library/PrivilegedHelperTools/com.boxx.helper</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>com.boxx.helper</key>
                <true/>
            </dict>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """
        // Write plist to temp first, then the script moves it to /Library
        let tmpPlistPath = "/tmp/com.boxx.helper.plist"
        try? plistXML.write(toFile: tmpPlistPath, atomically: true, encoding: .utf8)

        let scriptContent = """
        #!/bin/bash
        set -e
        launchctl bootout system/com.boxx.helper 2>/dev/null || true
        sleep 0.5
        mkdir -p /Library/PrivilegedHelperTools
        cp '\(helperSrc)' '/Library/PrivilegedHelperTools/com.boxx.helper'
        chmod 755 '/Library/PrivilegedHelperTools/com.boxx.helper'
        chown root:wheel '/Library/PrivilegedHelperTools/com.boxx.helper'
        mv '\(tmpPlistPath)' '/Library/LaunchDaemons/com.boxx.helper.plist'
        chmod 644 '/Library/LaunchDaemons/com.boxx.helper.plist'
        chown root:wheel '/Library/LaunchDaemons/com.boxx.helper.plist'
        launchctl bootstrap system '/Library/LaunchDaemons/com.boxx.helper.plist'
        """

        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            print("[BoxX] Failed to write install script: \(error)")
            return false
        }

        let appleScriptSrc = "do shell script \"/bin/bash '\(scriptPath)'\" with administrator privileges"

        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var error: NSDictionary?
                let appleScript = NSAppleScript(source: appleScriptSrc)
                appleScript?.executeAndReturnError(&error)
                try? FileManager.default.removeItem(atPath: scriptPath)
                if let error {
                    print("[BoxX] Helper install failed: \(error)")
                    cont.resume(returning: false)
                } else {
                    Thread.sleep(forTimeInterval: 1)
                    print("[BoxX] Helper installed successfully")
                    cont.resume(returning: true)
                }
            }
        }
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
    case startFailed(String)
    var errorDescription: String? {
        switch self {
        case .startFailed(let msg): return "启动失败: \(msg)"
        }
    }
}

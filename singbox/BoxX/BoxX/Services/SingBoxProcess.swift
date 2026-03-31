// BoxX/Services/SingBoxProcess.swift
import Foundation
import AppKit

@MainActor
@Observable
class SingBoxProcess {
    var isRunning: Bool = false
    private let singBoxPath = "/opt/homebrew/bin/sing-box"

    /// Start sing-box with admin privileges (for TUN). Runs async to avoid blocking UI.
    func start(configPath: String, mixedPort: Int = 7890) async throws {
        guard FileManager.default.fileExists(atPath: singBoxPath) else {
            throw SingBoxError.notInstalled
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw SingBoxError.startFailed("配置文件不存在: \(configPath)")
        }

        // Build launcher script that handles everything: kill old, start new
        let sbPath = singBoxPath
        let escapedConfigPath = configPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedConfigDir = URL(fileURLWithPath: configPath).deletingLastPathComponent().path
            .replacingOccurrences(of: "'", with: "'\\''")

        // Single osascript call: kill old (as root) + start new (as root)
        // Also set up sudoers rule so current user can send SIGHUP without password (for hot-reload)
        let currentUser = NSUserName()
        let launcherScript = """
        #!/bin/bash
        # Kill ALL existing sing-box processes
        pkill -x sing-box 2>/dev/null
        sleep 1
        pkill -9 -x sing-box 2>/dev/null
        # Wait for port \(mixedPort) to be released (up to 10 seconds)
        for i in $(seq 1 20); do
            if ! lsof -i :\(mixedPort) >/dev/null 2>&1; then break; fi
            sleep 0.5
        done
        # Allow current user to send signals to sing-box without password (for hot-reload)
        SUDOERS_FILE="/etc/sudoers.d/boxx-singbox"
        echo '\(currentUser) ALL=(root) NOPASSWD: /usr/bin/pkill -HUP -x sing-box, /usr/bin/pkill -x sing-box, /usr/bin/pkill -9 -x sing-box, /bin/kill -HUP *, /usr/bin/killall -HUP mDNSResponder, \(sbPath) run *, /bin/rm -f \(escapedConfigDir)/cache.db' > "$SUDOERS_FILE"
        chmod 0440 "$SUDOERS_FILE"
        # Keep cache.db to avoid re-downloading rule sets on every restart
        # cache.db is only cleared when user clicks "全部更新" in rule sets view
        # Rotate logs: rename current log with date, delete logs older than 3 days
        LOG_DIR="/tmp"
        LOG_FILE="$LOG_DIR/boxx-singbox.log"
        if [ -f "$LOG_FILE" ]; then
            mv "$LOG_FILE" "$LOG_DIR/boxx-singbox-$(date +%Y%m%d-%H%M%S).log"
        fi
        find "$LOG_DIR" -name "boxx-singbox-*.log" -mtime +3 -delete 2>/dev/null
        # Also clean up legacy error log
        rm -f /tmp/boxx-singbox-error.log
        # Start sing-box (background, redirect output to log)
        cd '\(escapedConfigDir)'
        '\(sbPath)' run -c '\(escapedConfigPath)' >>"$LOG_FILE" 2>&1 &
        """
        let launcherPath = "/tmp/boxx-launcher.sh"

        do {
            try launcherScript.write(toFile: launcherPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: launcherPath)
        } catch {
            throw SingBoxError.startFailed("无法创建启动脚本: \(error.localizedDescription)")
        }

        print("[BoxX] Starting sing-box with admin privileges...")

        // Show progress window
        let progressWindow = StartProgressWindow()
        progressWindow.show(message: "正在获取管理员权限...")

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
            progressWindow.close()
            throw SingBoxError.startFailed("授权被取消")
        }

        progressWindow.show(message: "正在启动 sing-box...")
        progressWindow.startLogMonitor()

        // Wait for Clash API on background thread (up to 60s for first-time rule-set downloads)
        let ready = await runOnBackground { () -> Bool in
            for _ in 0..<120 {
                if self.checkClashAPISync() { return true }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return false
        }

        progressWindow.stopLogMonitor()

        if ready {
            isRunning = true
            progressWindow.close()
            print("[BoxX] sing-box started ✅")
        } else if await runOnBackground({ self.findSingBoxPID() }) != nil {
            isRunning = true
            progressWindow.close()
            print("[BoxX] sing-box running (API slow)")
        } else {
            progressWindow.close()
            let errorLog = (try? String(contentsOfFile: "/tmp/boxx-singbox.log", encoding: .utf8)) ?? ""
            let fatalLines = errorLog.components(separatedBy: "\n")
                .filter { $0.contains("FATAL") }
                .prefix(3)
                .joined(separator: "\n")
            let detail = fatalLines.isEmpty ? "sing-box 启动后退出，请检查配置" : fatalLines
            throw SingBoxError.startFailed(detail)
        }

        // 启动成功后刷新 DNS 缓存
        if isRunning {
            flushDNS()
        }
    }

    /// Stop sing-box
    func stop() async {
        print("[BoxX] Stopping sing-box...")
        await runOnBackground {
            // Use sudo pkill (sudoers rule allows this without password)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            proc.arguments = ["pkill", "-x", "sing-box"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            self.waitForPortReleaseSync()
        }
        isRunning = false
        print("[BoxX] Stopped ✅")
    }

    /// Restart — stop via sudo (no password) + start via osascript (reuses existing start logic)
    func restart(configPath: String, mixedPort: Int = 7890) async throws {
        print("[BoxX] Restarting sing-box...")
        // stop() uses sudo pkill — no password needed (sudoers rule)
        await stop()
        // start() handles everything: kill remaining, start new process
        try await start(configPath: configPath, mixedPort: mixedPort)
    }

    /// Hot-reload config by sending SIGHUP via sudo (no password needed after first start)
    func reload() async {
        await runOnBackground {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            proc.arguments = ["pkill", "-HUP", "-x", "sing-box"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
        print("[BoxX] Config reloaded via SIGHUP")
    }

    /// Check if running
    func refreshStatus() async -> Bool {
        let reachable = await runOnBackground { self.checkClashAPISync() }
        isRunning = reachable
        return reachable
    }

    /// Flush DNS — must do both: clear cache + restart mDNSResponder
    func flushDNS() {
        // 1. dscacheutil -flushcache (清除 DNS 缓存)
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush.arguments = ["-flushcache"]
        flush.standardOutput = FileHandle.nullDevice
        flush.standardError = FileHandle.nullDevice
        try? flush.run()
        flush.waitUntilExit()

        // 2. sudo killall -HUP mDNSResponder (重启 DNS 解析服务，让新的 DNS 配置生效)
        //    sudoers 规则允许 kill -HUP，mDNSResponder 属于 root 需要 sudo
        let killDNS = Process()
        killDNS.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        killDNS.arguments = ["-n", "killall", "-HUP", "mDNSResponder"]  // -n = 非交互，不弹密码
        killDNS.standardOutput = FileHandle.nullDevice
        killDNS.standardError = FileHandle.nullDevice
        try? killDNS.run()
        killDNS.waitUntilExit()
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
        // MUST bypass proxy — otherwise TUN mode creates a loop
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]  // No proxy
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

// MARK: - Start Progress Window

@MainActor
class StartProgressWindow {
    private var window: NSWindow?
    private var label: NSTextField?
    private var monitorTask: Task<Void, Never>?

    func show(message: String) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            w.title = "BoxX"
            w.center()
            w.isReleasedWhenClosed = false
            w.level = .floating

            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 12
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)

            let lbl = NSTextField(labelWithString: message)
            lbl.font = NSFont.systemFont(ofSize: 13)
            lbl.lineBreakMode = .byTruncatingTail
            lbl.maximumNumberOfLines = 2

            stack.addArrangedSubview(spinner)
            stack.addArrangedSubview(lbl)

            w.contentView?.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: w.contentView!.centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: w.contentView!.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: w.contentView!.trailingAnchor, constant: -20),
            ])

            self.window = w
            self.label = lbl
        }
        label?.stringValue = message
        window?.makeKeyAndOrderFront(nil)
    }

    func startLogMonitor() {
        monitorTask = Task { @MainActor in
            let logPath = "/tmp/boxx-singbox.log"
            var lastSize: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
                      let size = attrs[.size] as? UInt64, size > lastSize else { continue }
                if let handle = FileHandle(forReadingAtPath: logPath) {
                    handle.seek(toFileOffset: max(0, size - 500))
                    if let tail = String(data: handle.readDataToEndOfFile(), encoding: .utf8) {
                        let lastLine = tail.components(separatedBy: "\n").filter { !$0.isEmpty }.last ?? ""
                        if lastLine.contains("updated rule-set") {
                            let name = lastLine.components(separatedBy: "updated rule-set ").last ?? ""
                            label?.stringValue = "正在下载规则集: \(name)"
                        } else if lastLine.contains("sing-box started") || lastLine.contains("inbound/") {
                            label?.stringValue = "sing-box 已启动，等待就绪..."
                        } else if lastLine.contains("rule-set take too much time") {
                            label?.stringValue = "规则集下载较慢，请耐心等待..."
                        }
                    }
                    handle.closeFile()
                }
                lastSize = size
            }
        }
    }

    func stopLogMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func close() {
        stopLogMonitor()
        window?.close()
        window = nil
        label = nil
    }
}

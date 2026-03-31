// BoxX/Services/SingBoxProcess.swift
import Foundation
import AppKit

@MainActor
@Observable
class SingBoxProcess {
    var isRunning: Bool = false
    var progressMessage: String?
    private let singBoxPath = "/opt/homebrew/bin/sing-box"
    private let plistPath = "/Library/LaunchDaemons/com.boxx.singbox.plist"
    private let plistLabel = "com.boxx.singbox"

    // MARK: - Plist Generation

    private func buildPlistContent(configPath: String, runAtLoad: Bool) -> String {
        let configDir = URL(fileURLWithPath: configPath).deletingLastPathComponent().path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(plistLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(singBoxPath)</string>
                <string>run</string>
                <string>-c</string>
                <string>\(configPath)</string>
            </array>
            <key>WorkingDirectory</key>
            <string>\(configDir)</string>
            <key>RunAtLoad</key>
            <\(runAtLoad ? "true" : "false")/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/tmp/boxx-singbox.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/boxx-singbox.log</string>
        </dict>
        </plist>
        """
    }

    // MARK: - Plist Installation (requires admin auth once)

    private func installPlist(configPath: String, mixedPort: Int) async throws {
        let runAtLoad = UserDefaults.standard.bool(forKey: "singboxRunAtLoad")
        let plistContent = buildPlistContent(configPath: configPath, runAtLoad: runAtLoad)
        let tmpPlist = "/tmp/com.boxx.singbox.plist"

        do {
            try plistContent.write(toFile: tmpPlist, atomically: true, encoding: .utf8)
        } catch {
            throw SingBoxError.startFailed("无法创建 plist: \(error.localizedDescription)")
        }

        let currentUser = NSUserName()
        let escapedConfigDir = URL(fileURLWithPath: configPath).deletingLastPathComponent().path
            .replacingOccurrences(of: "'", with: "'\\''")

        let installScript = """
        #!/bin/bash
        # Unload existing daemon if loaded
        launchctl bootout system/\(plistLabel) 2>/dev/null
        # Kill ALL existing sing-box processes
        pkill -x sing-box 2>/dev/null
        sleep 1
        pkill -9 -x sing-box 2>/dev/null
        # Wait for port \(mixedPort) to be released
        for i in $(seq 1 20); do
            if ! lsof -i :\(mixedPort) >/dev/null 2>&1; then break; fi
            sleep 0.5
        done
        # Install plist
        cp '\(tmpPlist)' '\(plistPath)'
        chown root:wheel '\(plistPath)'
        chmod 644 '\(plistPath)'
        # Setup sudoers for passwordless operations
        SUDOERS_FILE="/etc/sudoers.d/boxx-singbox"
        cat > "$SUDOERS_FILE" << 'SUDOERS'
        \(currentUser) ALL=(root) NOPASSWD: /bin/launchctl bootstrap system \(plistPath)
        \(currentUser) ALL=(root) NOPASSWD: /bin/launchctl bootout system/\(plistLabel)
        \(currentUser) ALL=(root) NOPASSWD: /bin/launchctl kickstart -k system/\(plistLabel)
        \(currentUser) ALL=(root) NOPASSWD: /usr/bin/pkill -HUP -x sing-box
        \(currentUser) ALL=(root) NOPASSWD: /usr/bin/pkill -x sing-box
        \(currentUser) ALL=(root) NOPASSWD: /usr/bin/pkill -9 -x sing-box
        \(currentUser) ALL=(root) NOPASSWD: /bin/kill -HUP *
        \(currentUser) ALL=(root) NOPASSWD: /usr/bin/killall -HUP mDNSResponder
        \(currentUser) ALL=(root) NOPASSWD: /usr/bin/tee \(plistPath)
        \(currentUser) ALL=(root) NOPASSWD: /bin/rm -f \(escapedConfigDir)/cache.db
        SUDOERS
        chmod 0440 "$SUDOERS_FILE"
        # Rotate logs
        LOG_DIR="/tmp"
        LOG_FILE="$LOG_DIR/boxx-singbox.log"
        if [ -f "$LOG_FILE" ]; then
            mv "$LOG_FILE" "$LOG_DIR/boxx-singbox-$(date +%Y%m%d-%H%M%S).log"
        fi
        find "$LOG_DIR" -name "boxx-singbox-*.log" -mtime +3 -delete 2>/dev/null
        rm -f /tmp/boxx-singbox-error.log
        # Clean up legacy launcher
        rm -f /tmp/boxx-launcher.sh
        # Load the daemon
        launchctl bootstrap system '\(plistPath)'
        """

        let scriptPath = "/tmp/boxx-install-daemon.sh"
        try installScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: scriptPath)

        let exitCode = await runOnBackground { () -> Int32 in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "do shell script \"\(scriptPath)\" with administrator privileges"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        }

        if exitCode != 0 {
            throw SingBoxError.startFailed("授权被取消")
        }
    }

    // MARK: - Start

    func start(configPath: String, mixedPort: Int = 7890) async throws {
        // Skip if already running
        if await refreshStatus() {
            print("[BoxX] sing-box already running, skipping start")
            return
        }
        guard FileManager.default.fileExists(atPath: singBoxPath) else {
            throw SingBoxError.notInstalled
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw SingBoxError.startFailed("配置文件不存在: \(configPath)")
        }

        print("[BoxX] Starting sing-box via launchd...")

        progressMessage = "正在启动 sing-box..."

        if !isPlistInstalled() {
            progressMessage = "正在获取管理员权限..."
            try await installPlist(configPath: configPath, mixedPort: mixedPort)
        } else {
            await updatePlistConfigPath(configPath)
            progressMessage = "正在启动 sing-box..."
            await runOnBackground {
                let unload = Process()
                unload.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                unload.arguments = ["-n", "launchctl", "bootout", "system/\(self.plistLabel)"]
                unload.standardOutput = FileHandle.nullDevice
                unload.standardError = FileHandle.nullDevice
                try? unload.run()
                unload.waitUntilExit()

                let pkill = Process()
                pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                pkill.arguments = ["-n", "pkill", "-9", "-x", "sing-box"]
                pkill.standardOutput = FileHandle.nullDevice
                pkill.standardError = FileHandle.nullDevice
                try? pkill.run()
                pkill.waitUntilExit()

                Thread.sleep(forTimeInterval: 1)

                let load = Process()
                load.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                load.arguments = ["-n", "launchctl", "bootstrap", "system", self.plistPath]
                load.standardOutput = FileHandle.nullDevice
                load.standardError = FileHandle.nullDevice
                try? load.run()
                load.waitUntilExit()
            }
        }

        progressMessage = "正在等待 sing-box 就绪..."

        // Wait for Clash API (up to 60s for first-time rule-set downloads)
        let ready = await runOnBackground { () -> Bool in
            for _ in 0..<120 {
                if self.checkClashAPISync() { return true }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return false
        }

        if ready {
            isRunning = true
            progressMessage = nil
            print("[BoxX] sing-box started via launchd ✅")
        } else if await runOnBackground({ self.findSingBoxPID() }) != nil {
            isRunning = true
            progressMessage = nil
            print("[BoxX] sing-box running (API slow)")
        } else {
            progressMessage = nil
            let errorLog = (try? String(contentsOfFile: "/tmp/boxx-singbox.log", encoding: .utf8)) ?? ""
            let fatalLines = errorLog.components(separatedBy: "\n")
                .filter { $0.contains("FATAL") }
                .prefix(3)
                .joined(separator: "\n")
            let detail = fatalLines.isEmpty ? "sing-box 启动后退出，请检查配置" : fatalLines
            throw SingBoxError.startFailed(detail)
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
        await runOnBackground {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            proc.arguments = ["-n", "launchctl", "bootout", "system/\(self.plistLabel)"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            // Also kill any remaining processes
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            pkill.arguments = ["-n", "pkill", "-x", "sing-box"]
            pkill.standardOutput = FileHandle.nullDevice
            pkill.standardError = FileHandle.nullDevice
            try? pkill.run()
            pkill.waitUntilExit()
            self.waitForPortReleaseSync()
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
        await runOnBackground {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            proc.arguments = ["-n", "pkill", "-HUP", "-x", "sing-box"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
        print("[BoxX] Config reloaded via SIGHUP")
    }

    // MARK: - Status

    func refreshStatus() async -> Bool {
        let reachable = await runOnBackground { self.checkClashAPISync() }
        isRunning = reachable
        return reachable
    }

    // MARK: - RunAtLoad Toggle

    func updateRunAtLoad(_ enabled: Bool) async {
        guard isPlistInstalled() else { return }
        // Read current plist, modify RunAtLoad, write back via sudo tee
        guard let data = FileManager.default.contents(atPath: plistPath),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        plist["RunAtLoad"] = enabled
        guard let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let tmpPath = "/tmp/com.boxx.singbox.plist.tmp"
        try? newData.write(to: URL(fileURLWithPath: tmpPath))

        await runOnBackground {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", "sudo -n tee '\(self.plistPath)' < '\(tmpPath)' > /dev/null"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: tmpPath)
        print("[BoxX] RunAtLoad set to \(enabled)")
    }

    // MARK: - Plist Helpers

    func isPlistInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    private func updatePlistConfigPath(_ configPath: String) async {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              args.last != configPath else { return }
        // Config path changed, regenerate plist
        let runAtLoad = UserDefaults.standard.bool(forKey: "singboxRunAtLoad")
        let content = buildPlistContent(configPath: configPath, runAtLoad: runAtLoad)
        let tmpPath = "/tmp/com.boxx.singbox.plist.tmp"
        try? content.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        await runOnBackground {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", "sudo -n tee '\(self.plistPath)' < '\(tmpPath)' > /dev/null"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    // MARK: - DNS

    func flushDNS() {
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush.arguments = ["-flushcache"]
        flush.standardOutput = FileHandle.nullDevice
        flush.standardError = FileHandle.nullDevice
        try? flush.run()
        flush.waitUntilExit()

        let killDNS = Process()
        killDNS.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        killDNS.arguments = ["-n", "killall", "-HUP", "mDNSResponder"]
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

// MARK: - Start Progress Window (unused, kept for reference)
// Progress is now shown inline in OverviewView via SingBoxProcess.progressMessage

/*
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
                    handle.seek(toFileOffset: size > 500 ? size - 500 : 0)
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
*/

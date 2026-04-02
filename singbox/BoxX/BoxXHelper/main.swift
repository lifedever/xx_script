import Foundation
import Security

final class HelperTool: NSObject, HelperProtocol, NSXPCListenerDelegate {
    private var singBoxProcess: Process?
    private let serialQueue = DispatchQueue(label: "com.boxx.helper.serial")
    private var lastConfigPath: String?
    private var isStopping = false
    /// Pending watchProcessExit callbacks
    private var exitWatchers: [(Bool, Int32) -> Void] = []
    private var processSource: DispatchSourceProcess?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Validate caller's code signature
        let pid = connection.processIdentifier
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let secCode = code else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(secCode, [], &staticCode) == errSecSuccess,
              let sc = staticCode else {
            return false
        }
        var requirement: SecRequirement?
        SecRequirementCreateWithString("identifier \"com.boxx.app\"" as CFString, [], &requirement)
        if let req = requirement {
            guard SecStaticCodeCheckValidity(sc, [], req) == errSecSuccess else {
                return false
            }
        }

        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: - Start

    func startSingBox(configPath: String, withReply reply: @escaping (Bool, String?) -> Void) {
        serialQueue.async { [self] in
            guard (configPath.hasPrefix("/tmp/boxx/") || configPath.contains("/Library/Application Support/BoxX/")) && configPath.hasSuffix(".json") else {
                reply(false, "Invalid config path")
                return
            }
            guard FileManager.default.fileExists(atPath: HelperConstants.singBoxPath) else {
                reply(false, "sing-box not found at \(HelperConstants.singBoxPath)")
                return
            }

            isStopping = false

            // Kill any existing sing-box process first
            killAllSingBox()
            waitForCleanup()

            // Rotate logs
            rotateLog()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: HelperConstants.singBoxPath)
            process.arguments = ["run", "-c", configPath]
            let configDir = (configPath as NSString).deletingLastPathComponent
            process.currentDirectoryURL = URL(fileURLWithPath: configDir)
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": "/var/root",
            ]
            umask(0o022)

            // Log to file
            let logPath = "/tmp/boxx-singbox.log"
            FileManager.default.createFile(atPath: logPath, contents: nil)
            let logHandle = FileHandle(forWritingAtPath: logPath)
            process.standardOutput = logHandle ?? FileHandle.nullDevice
            process.standardError = logHandle ?? FileHandle.nullDevice

            do {
                try process.run()
                singBoxProcess = process
                lastConfigPath = configPath

                // Poll up to 3 seconds to confirm process stays alive
                var isAlive = false
                for _ in 0..<30 {
                    usleep(100_000)
                    if !process.isRunning { break }
                    isAlive = true
                }
                if isAlive {
                    // Setup process exit monitoring
                    setupProcessMonitor(pid: process.processIdentifier)
                    reply(true, nil)
                } else {
                    let stderrData = (try? Data(contentsOf: URL(fileURLWithPath: logPath))) ?? Data()
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                    let lastLines = stderrStr.components(separatedBy: "\n").suffix(5).joined(separator: "\n")
                    reply(false, "sing-box exited (code \(process.terminationStatus)): \(lastLines)")
                    singBoxProcess = nil
                    lastConfigPath = nil
                }
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    // MARK: - Stop

    func stopSingBox(withReply reply: @escaping (Bool, String?) -> Void) {
        serialQueue.async { [self] in
            isStopping = true
            cancelProcessMonitor()

            if let proc = singBoxProcess, proc.isRunning {
                proc.terminate()
                for _ in 0..<20 {
                    if !proc.isRunning { break }
                    usleep(100_000)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                    usleep(200_000)
                }
            }
            singBoxProcess = nil

            // Also kill any orphan sing-box processes
            killAllSingBox()
            waitForCleanup()

            // Notify watchers that process stopped (deliberate)
            notifyWatchers(exitCode: 0)

            reply(true, nil)
        }
    }

    // MARK: - Status

    func getStatus(withReply reply: @escaping (Bool, Int32) -> Void) {
        serialQueue.async { [self] in
            if let proc = singBoxProcess, proc.isRunning {
                reply(true, proc.processIdentifier)
                return
            }
            // Check for orphan process
            if let pid = findSingBoxPID() {
                reply(true, pid)
            } else {
                reply(false, 0)
            }
        }
    }

    // MARK: - Reload

    func reloadSingBox(withReply reply: @escaping (Bool, String?) -> Void) {
        serialQueue.async { [self] in
            if let proc = singBoxProcess, proc.isRunning {
                kill(proc.processIdentifier, SIGHUP)
                reply(true, nil)
                return
            }
            if let pid = findSingBoxPID() {
                kill(pid, SIGHUP)
                reply(true, nil)
                return
            }
            reply(false, "sing-box is not running")
        }
    }

    // MARK: - DNS

    func flushDNS(withReply reply: @escaping (Bool) -> Void) {
        serialQueue.async {
            let flush = Process()
            flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
            flush.arguments = ["-flushcache"]
            try? flush.run()
            flush.waitUntilExit()

            let killMDNS = Process()
            killMDNS.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killMDNS.arguments = ["-HUP", "mDNSResponder"]
            try? killMDNS.run()
            killMDNS.waitUntilExit()

            reply(true)
        }
    }

    // MARK: - System Proxy

    func setSystemProxy(port: Int32, withReply reply: @escaping (Bool) -> Void) {
        serialQueue.async {
            let services = ["Wi-Fi", "Ethernet"]
            let types = [
                ("setwebproxy", String(port)),
                ("setsecurewebproxy", String(port)),
                ("setsocksfirewallproxy", String(port))
            ]
            for service in services {
                for (flag, p) in types {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    proc.arguments = ["-\(flag)", service, "127.0.0.1", p]
                    proc.standardOutput = FileHandle.nullDevice
                    proc.standardError = FileHandle.nullDevice
                    try? proc.run()
                    proc.waitUntilExit()
                }
            }
            reply(true)
        }
    }

    func clearSystemProxy(withReply reply: @escaping (Bool) -> Void) {
        serialQueue.async {
            let services = ["Wi-Fi", "Ethernet"]
            let types = ["setwebproxystate", "setsecurewebproxystate", "setsocksfirewallproxystate"]
            for service in services {
                for flag in types {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    proc.arguments = ["-\(flag)", service, "off"]
                    proc.standardOutput = FileHandle.nullDevice
                    proc.standardError = FileHandle.nullDevice
                    try? proc.run()
                    proc.waitUntilExit()
                }
            }
            reply(true)
        }
    }

    // MARK: - Watch Process Exit

    func watchProcessExit(withReply reply: @escaping (Bool, Int32) -> Void) {
        serialQueue.async { [self] in
            // If not running, reply immediately
            let pid: Int32?
            if let proc = singBoxProcess, proc.isRunning {
                pid = proc.processIdentifier
            } else {
                pid = findSingBoxPID()
            }

            guard let activePID = pid else {
                reply(false, 0)
                return
            }

            // If we already have a monitor, just add the watcher
            exitWatchers.append(reply)

            // Setup monitor if not already active
            if processSource == nil {
                setupProcessMonitor(pid: activePID)
            }
        }
    }

    // MARK: - Legacy Migration

    func removeLegacyDaemon(withReply reply: @escaping (Bool) -> Void) {
        serialQueue.async {
            let legacyPlist = "/Library/LaunchDaemons/com.boxx.singbox.plist"
            let legacySudoers = "/etc/sudoers.d/boxx-singbox"

            // Unload legacy daemon
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "system/com.boxx.singbox"]
            bootout.standardOutput = FileHandle.nullDevice
            bootout.standardError = FileHandle.nullDevice
            try? bootout.run()
            bootout.waitUntilExit()

            // Remove files
            try? FileManager.default.removeItem(atPath: legacyPlist)
            try? FileManager.default.removeItem(atPath: legacySudoers)

            reply(true)
        }
    }

    // MARK: - Process Monitoring

    private func setupProcessMonitor(pid: Int32) {
        cancelProcessMonitor()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: serialQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelProcessMonitor()

            let exitCode = self.singBoxProcess?.terminationStatus ?? -1
            self.singBoxProcess = nil

            // Notify all watchers
            self.notifyWatchers(exitCode: exitCode)

            // Auto-restart on crash (not deliberate stop)
            if !self.isStopping, let configPath = self.lastConfigPath {
                // Wait 2 seconds before restarting to avoid rapid loops
                sleep(2)
                self.startSingBox(configPath: configPath) { success, error in
                    if success {
                        print("[BoxXHelper] Auto-restarted sing-box after crash")
                    } else {
                        print("[BoxXHelper] Auto-restart failed: \(error ?? "unknown")")
                    }
                }
            }
        }
        source.resume()
        processSource = source
    }

    private func cancelProcessMonitor() {
        processSource?.cancel()
        processSource = nil
    }

    private func notifyWatchers(exitCode: Int32) {
        let watchers = exitWatchers
        exitWatchers.removeAll()
        for watcher in watchers {
            watcher(true, exitCode)
        }
    }

    // MARK: - Helpers

    private func findSingBoxPID() -> Int32? {
        let finder = Process()
        finder.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        finder.arguments = ["-x", "sing-box"]
        let pipe = Pipe()
        finder.standardOutput = pipe
        try? finder.run()
        finder.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              let pid = Int32(output.components(separatedBy: "\n").first ?? "") else {
            return nil
        }
        return pid
    }

    private func killAllSingBox() {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-x", "sing-box"]
        try? killer.run()
        killer.waitUntilExit()

        for _ in 0..<30 {
            if findSingBoxPID() == nil { return }
            usleep(100_000)
        }

        let forceKiller = Process()
        forceKiller.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        forceKiller.arguments = ["-9", "-x", "sing-box"]
        try? forceKiller.run()
        forceKiller.waitUntilExit()
        usleep(500_000)
    }

    private func waitForCleanup() {
        for _ in 0..<30 {
            if !isPortInUse(7890) && !isPortInUse(9091) { return }
            usleep(100_000)
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

    private func rotateLog() {
        let logPath = "/tmp/boxx-singbox.log"
        let fm = FileManager.default
        if fm.fileExists(atPath: logPath) {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            let backup = "/tmp/boxx-singbox-\(df.string(from: Date())).log"
            try? fm.moveItem(atPath: logPath, toPath: backup)
        }
        // Clean old logs (>3 days)
        if let files = try? fm.contentsOfDirectory(atPath: "/tmp") {
            for file in files where file.hasPrefix("boxx-singbox-") && file.hasSuffix(".log") {
                let path = "/tmp/\(file)"
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let date = attrs[.modificationDate] as? Date,
                   Date().timeIntervalSince(date) > 3 * 86400 {
                    try? fm.removeItem(atPath: path)
                }
            }
        }
    }
}

let tool = HelperTool()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = tool
listener.resume()
RunLoop.current.run()

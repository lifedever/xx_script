import Foundation
import Security

final class HelperTool: NSObject, HelperProtocol, NSXPCListenerDelegate {
    private var singBoxProcess: Process?
    private let serialQueue = DispatchQueue(label: "com.boxx.helper.serial")

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

            // Kill any existing sing-box process first
            killAllSingBox()

            // Wait for ports and TUN to be released
            waitForCleanup()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: HelperConstants.singBoxPath)
            process.arguments = ["run", "-c", configPath]
            // Set working directory to config's directory
            let configDir = (configPath as NSString).deletingLastPathComponent
            process.currentDirectoryURL = URL(fileURLWithPath: configDir)
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": "/var/root",
            ]
            umask(0o022)

            // Capture stderr for error reporting
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            // Don't capture stdout (sing-box writes logs there)
            process.standardOutput = FileHandle.nullDevice

            do {
                try process.run()
                singBoxProcess = process

                // Poll up to 3 seconds to confirm process stays alive
                var isAlive = false
                for _ in 0..<30 {
                    usleep(100_000)
                    if !process.isRunning { break }
                    isAlive = true
                }
                if isAlive {
                    reply(true, nil)
                } else {
                    // Read stderr for error details
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                    let lastLines = stderrStr.components(separatedBy: "\n").suffix(5).joined(separator: "\n")
                    reply(false, "sing-box exited (code \(process.terminationStatus)): \(lastLines)")
                    singBoxProcess = nil
                }
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func stopSingBox(withReply reply: @escaping (Bool, String?) -> Void) {
        serialQueue.async { [self] in
            // Kill managed process
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

            // Wait for cleanup
            waitForCleanup()

            reply(true, nil)
        }
    }

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

    // MARK: - v2 New Methods

    func reloadSingBox(withReply reply: @escaping (Bool, String?) -> Void) {
        serialQueue.async { [self] in
            // Try managed process first
            if let proc = singBoxProcess, proc.isRunning {
                kill(proc.processIdentifier, SIGHUP)
                reply(true, nil)
                return
            }
            // Try orphan process
            if let pid = findSingBoxPID() {
                kill(pid, SIGHUP)
                reply(true, nil)
                return
            }
            reply(false, "sing-box is not running")
        }
    }

    func flushDNS(withReply reply: @escaping (Bool) -> Void) {
        serialQueue.async {
            // Flush DNS cache (runs as root)
            let flush = Process()
            flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
            flush.arguments = ["-flushcache"]
            try? flush.run()
            flush.waitUntilExit()

            // Restart mDNSResponder
            let killMDNS = Process()
            killMDNS.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killMDNS.arguments = ["-HUP", "mDNSResponder"]
            try? killMDNS.run()
            killMDNS.waitUntilExit()

            reply(true)
        }
    }

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

    // MARK: - Helpers

    /// Find PID of running sing-box
    private func findSingBoxPID() -> Int32? {
        let finder = Process()
        finder.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        finder.arguments = ["-x", "sing-box"]  // exact match, not -f
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

    /// Kill all sing-box processes
    private func killAllSingBox() {
        // Use pkill -x for exact process name match (not -f which matches args)
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-x", "sing-box"]
        try? killer.run()
        killer.waitUntilExit()

        // Wait for processes to die
        for _ in 0..<30 {
            if findSingBoxPID() == nil { return }
            usleep(100_000)
        }

        // Force kill if still alive
        let forceKiller = Process()
        forceKiller.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        forceKiller.arguments = ["-9", "-x", "sing-box"]
        try? forceKiller.run()
        forceKiller.waitUntilExit()
        usleep(500_000)
    }

    /// Wait for port 7890 and 9091 to be released
    private func waitForCleanup() {
        for _ in 0..<30 {  // up to 3 seconds
            if !isPortInUse(7890) && !isPortInUse(9091) { return }
            usleep(100_000)
        }
    }

    /// Check if a TCP port is in use
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
        return result != 0  // bind fails = port in use
    }
}

let tool = HelperTool()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = tool
listener.resume()
RunLoop.current.run()

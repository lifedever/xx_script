import Foundation

final class HelperTool: NSObject, HelperProtocol, NSXPCListenerDelegate {
    private var singBoxProcess: Process?
    private let serialQueue = DispatchQueue(label: "com.boxx.helper.serial")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let secCode = code else {
            return false
        }
        var info: CFDictionary?
        // SecCodeCopySigningInformation requires SecStaticCode; SecCode is a subtype — bridge via unsafeBitCast
        let staticCode = unsafeBitCast(secCode, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let bundleId = dict["identifier"] as? String,
              bundleId == "com.boxx.app" else {
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func startSingBox(configPath: String, withReply reply: @escaping (Bool, String?) -> Void) {
        serialQueue.async { [self] in
            guard configPath.contains("/singbox/") && configPath.hasSuffix(".json") else {
                reply(false, "Invalid config path")
                return
            }
            guard FileManager.default.fileExists(atPath: HelperConstants.singBoxPath) else {
                reply(false, "sing-box not found at \(HelperConstants.singBoxPath)")
                return
            }
            if let proc = singBoxProcess, proc.isRunning {
                proc.terminate()
                usleep(500_000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                singBoxProcess = nil
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: HelperConstants.singBoxPath)
            process.arguments = ["run", "-c", configPath]
            process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
            umask(0o022)
            do {
                try process.run()
                singBoxProcess = process
                usleep(1_000_000)
                if process.isRunning {
                    reply(true, nil)
                } else {
                    reply(false, "sing-box exited immediately (code \(process.terminationStatus))")
                }
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func stopSingBox(withReply reply: @escaping (Bool, String?) -> Void) {
        serialQueue.async { [self] in
            guard let proc = singBoxProcess, proc.isRunning else {
                let finder = Process()
                finder.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                finder.arguments = ["-f", "sing-box run"]
                let pipe = Pipe()
                finder.standardOutput = pipe
                try? finder.run()
                finder.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    for pidStr in output.components(separatedBy: "\n") {
                        if let pid = Int32(pidStr) {
                            kill(pid, SIGTERM)
                        }
                    }
                    usleep(1_000_000)
                }
                singBoxProcess = nil
                reply(true, nil)
                return
            }
            proc.terminate()
            usleep(2_000_000)
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            singBoxProcess = nil
            reply(true, nil)
        }
    }

    func getStatus(withReply reply: @escaping (Bool, Int32) -> Void) {
        serialQueue.async { [self] in
            if let proc = singBoxProcess, proc.isRunning {
                reply(true, proc.processIdentifier)
                return
            }
            let finder = Process()
            finder.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            finder.arguments = ["-f", "sing-box run"]
            let pipe = Pipe()
            finder.standardOutput = pipe
            try? finder.run()
            finder.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(output.components(separatedBy: "\n").first ?? "") {
                reply(true, pid)
            } else {
                reply(false, 0)
            }
        }
    }
}

let tool = HelperTool()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = tool
listener.resume()
RunLoop.current.run()

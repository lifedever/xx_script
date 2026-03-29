import Foundation

final class ConfigGenerator {
    private let scriptDir: String

    init(scriptDir: String? = nil) {
        if let dir = scriptDir {
            self.scriptDir = dir
        } else {
            self.scriptDir = UserDefaults.standard.string(forKey: "scriptDir")
                ?? (NSHomeDirectory() + "/Documents/Dev/myspace/xx_script/singbox")
        }
    }

    var configPath: String { scriptDir + "/config.json" }
    var generatePyPath: String { scriptDir + "/generate.py" }

    func generate() -> AsyncStream<String> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [self.generatePyPath]
            process.currentDirectoryURL = URL(fileURLWithPath: self.scriptDir)
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": NSHomeDirectory(),
                "LANG": "en_US.UTF-8"
            ]

            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let line = String(data: data, encoding: .utf8) {
                    for l in line.components(separatedBy: "\n") where !l.isEmpty {
                        continuation.yield(l)
                    }
                }
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let line = String(data: data, encoding: .utf8) {
                    for l in line.components(separatedBy: "\n") where !l.isEmpty {
                        continuation.yield("[stderr] \(l)")
                    }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.yield("Config generation complete")
                } else {
                    continuation.yield("Failed with exit code \(proc.terminationStatus)")
                }
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.yield("Failed to run generate.py: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }
}

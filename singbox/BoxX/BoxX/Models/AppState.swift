import SwiftUI

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var isRunning = false
    var isUpdatingSubscription = false
    var errorMessage: String?
    var showError = false
    var pendingReload: Bool {
        didSet { UserDefaults.standard.set(pendingReload, forKey: "pendingReload") }
    }

    // v2: core services
    let configEngine: ConfigEngine
    let singBoxProcess: SingBoxProcess
    let api: ClashAPI
    let subscriptionService: SubscriptionService

    private init() {
        pendingReload = UserDefaults.standard.bool(forKey: "pendingReload")

        let baseDir = Self.resolveBaseDir()
        configEngine = ConfigEngine(baseDir: baseDir)
        singBoxProcess = SingBoxProcess()
        api = ClashAPI()
        subscriptionService = SubscriptionService(configEngine: configEngine)

        // When config deploys and sing-box is running, mark pending reload
        let process = singBoxProcess
        configEngine.onDeployComplete = { [weak self] in
            guard process.isRunning else { return }
            Task { @MainActor in
                self?.pendingReload = true
            }
        }
    }

    /// Resolve config base directory, auto-create if needed.
    /// Prefers /Library/Application Support/BoxX (shared, Helper can read).
    /// Falls back to ~/Library/Application Support/BoxX if no write permission.
    private static func resolveBaseDir() -> URL {
        let fm = FileManager.default
        let sharedDir = URL(fileURLWithPath: "/Library/Application Support/BoxX")
        let userDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BoxX")

        // Try shared directory first
        let baseDir: URL
        if fm.isWritableFile(atPath: "/Library/Application Support") ||
           fm.isWritableFile(atPath: sharedDir.path) {
            baseDir = sharedDir
        } else {
            baseDir = userDir
        }

        // Auto-create directory structure
        let subdirs = ["proxies", "rules"]
        for sub in [baseDir] + subdirs.map({ baseDir.appendingPathComponent($0) }) {
            if !fm.fileExists(atPath: sub.path) {
                try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
            }
        }

        // If config.json doesn't exist, create a minimal one
        let configFile = baseDir.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: configFile.path) {
            let minimal = """
            {
              "log": {"level": "info", "timestamp": true},
              "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7890}],
              "outbounds": [{"type": "selector", "tag": "Proxy", "outbounds": ["DIRECT"]}, {"type": "direct", "tag": "DIRECT"}],
              "route": {"rules": [], "final": "Proxy", "auto_detect_interface": true},
              "experimental": {"clash_api": {"external_controller": "127.0.0.1:9091", "default_mode": "Rule"}}
            }
            """
            try? minimal.data(using: .utf8)?.write(to: configFile)
        }

        return baseDir
    }

    func showAlert(_ message: String) {
        errorMessage = message
        showError = true
    }

    /// Apply pending config changes via SIGHUP (brief ~1s reconnect)
    func applyConfig() async {
        guard isRunning, pendingReload else { return }

        // Validate config before applying
        let rtPath = configEngine.baseDir.appendingPathComponent("runtime-config.json").path
        let valid = await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")
            proc.arguments = ["check", "-c", rtPath]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        }.value

        guard valid else {
            showAlert("配置校验失败，请检查后重试。不会应用当前配置。")
            return
        }

        await singBoxProcess.reload()
        pendingReload = false
    }
}

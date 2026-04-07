import Foundation
import ShadowProxyCore

let version = "0.1.0"
let configDir = NSHomeDirectory() + "/.shadowproxy"
let configPath = configDir + "/config.conf"
let pidPath = configDir + "/sp.pid"

@MainActor
func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        printUsage()
        return
    }

    switch command {
    case "start":   await start()
    case "stop":    stop()
    case "status":  status()
    case "select":  await selectNode(Array(args.dropFirst()))
    case "reload":  print("TODO: reload")
    case "version": print("ShadowProxy v\(version)")
    default:        printUsage()
    }
}

func printUsage() {
    print("""
    ShadowProxy v\(version) — Native macOS Proxy

    Usage:
      sp start       Start proxy (system proxy mode)
      sp stop        Stop proxy
      sp status      Show current status
      sp select <group> <node>   Select proxy node
      sp reload      Reload configuration
      sp version     Show version
    """)
}

@MainActor
func start() async {
    // Ensure config directory exists
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)

    // Check if already running
    if let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
       let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(pid, 0) == 0 {
        print("ShadowProxy is already running (PID: \(pid))")
        return
    }

    // Parse config
    guard FileManager.default.fileExists(atPath: configPath) else {
        print("Config file not found: \(configPath)")
        print("Create it with your proxy configuration.")
        return
    }

    let parser = ConfigParser()
    let config: AppConfig
    do {
        config = try parser.parse(fileAt: configPath)
    } catch {
        print("Failed to parse config: \(error)")
        return
    }

    print("Loaded \(config.proxies.count) proxies, \(config.groups.count) groups, \(config.rules.count) rules")

    // Load RULE-SET files
    let ruleSetURLs = config.rules.compactMap { rule -> (url: String, policy: String)? in
        if case .ruleSet(let url, let policy) = rule { return (url, policy) }
        return nil
    }

    var expandedRuleSets: [String: [Rule]] = [:]
    if !ruleSetURLs.isEmpty {
        print("Loading \(ruleSetURLs.count) rule sets...")
        let loader = RuleSetLoader(cacheDir: configDir + "/rulesets")
        expandedRuleSets = await loader.loadAll(ruleSets: ruleSetURLs)
        let totalRules = expandedRuleSets.values.reduce(0) { $0 + $1.count }
        print("Loaded \(totalRules) rules from rule sets")
    }

    let port = config.general.port

    // Create engine
    let engine = ProxyEngine(config: config, port: port, expandedRuleSets: expandedRuleSets)

    do {
        try engine.start()
    } catch {
        print("Failed to start engine: \(error)")
        return
    }

    // Set system proxy
    do {
        try SystemProxy.enable(port: port)
    } catch {
        print("Warning: Failed to set system proxy: \(error)")
        print("You can manually set HTTP/SOCKS proxy to 127.0.0.1:\(port)")
    }

    // Write PID
    try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: pidPath, atomically: true, encoding: .utf8)

    // Setup sleep watcher
    let sleepWatcher = SleepWatcher {
        print("[Wake] Checking proxy status...")
        if !SystemProxy.isEnabled(port: port) {
            try? SystemProxy.enable(port: port)
            print("[Wake] System proxy restored")
        }
    }
    sleepWatcher.start()

    // Handle signals for graceful shutdown
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler {
        print("\nShutting down...")
        engine.stop()
        try? SystemProxy.disable()
        try? FileManager.default.removeItem(atPath: pidPath)
        sleepWatcher.stop()
        exit(0)
    }
    signalSource.resume()

    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signal(SIGTERM, SIG_IGN)
    termSource.setEventHandler {
        print("Received SIGTERM, shutting down...")
        engine.stop()
        try? SystemProxy.disable()
        try? FileManager.default.removeItem(atPath: pidPath)
        sleepWatcher.stop()
        exit(0)
    }
    termSource.resume()

    print("""

    ✓ ShadowProxy is running
      Listen: 127.0.0.1:\(port)
      Mode:   System Proxy
      PID:    \(ProcessInfo.processInfo.processIdentifier)

    Press Ctrl+C to stop.
    """)

    // Keep running — suspend indefinitely
    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
        // Never resumed — process stays alive until signal handler calls exit(0)
    }
}

func stop() {
    guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
          let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        print("ShadowProxy is not running (no PID file)")
        return
    }

    if kill(pid, 0) != 0 {
        print("ShadowProxy is not running (stale PID file)")
        try? FileManager.default.removeItem(atPath: pidPath)
        return
    }

    kill(pid, SIGTERM)
    print("Sent SIGTERM to PID \(pid)")
}

func status() {
    let port = (try? ConfigParser().parse(fileAt: configPath))?.general.port ?? 7890
    if let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
       let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(pid, 0) == 0 {
        let proxyActive = SystemProxy.isEnabled(port: port)
        print("""
        ShadowProxy is running
          PID:          \(pid)
          System Proxy: \(proxyActive ? "Active" : "Inactive")
          Listen:       127.0.0.1:\(port)
        """)
    } else {
        print("ShadowProxy is not running")
    }
}

func selectNode(_ args: [String]) async {
    guard args.count >= 2 else {
        print("Usage: sp select <group> <node>")
        return
    }
    // This requires IPC with running process — Phase 2
    print("Node selection requires the running process. Use config file for now.")
}

await main()

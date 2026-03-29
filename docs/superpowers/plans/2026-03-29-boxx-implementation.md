# BoxX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu bar app (BoxX) wrapping sing-box CLI with YACD-equivalent dashboard and sleep/wake auto-recovery.

**Architecture:** SwiftUI app with MenuBarExtra + main window, Clash API client (HTTP/WebSocket to 127.0.0.1:9091), Privileged Helper via SMAppService.daemon for root sing-box process management, and WakeObserver for automatic network recovery.

**Tech Stack:** Swift 6, SwiftUI, Foundation (URLSession, WebSocket), XPC, SMAppService, xcodegen

**Spec:** `docs/superpowers/specs/2026-03-29-boxx-macos-client-design.md`

**Environment:** macOS 26.4, Xcode 26.4, sing-box 1.13.4 (arm64), xcodegen installed at `/opt/homebrew/bin/xcodegen`, sing-box at `/opt/homebrew/bin/sing-box`

---

## File Structure

```
singbox/BoxX/
├── project.yml                         # xcodegen project spec
├── BoxX/
│   ├── BoxXApp.swift                   # App entry: MenuBarExtra + WindowGroup
│   ├── AppState.swift                  # Shared observable app state
│   ├── MenuBar/
│   │   └── MenuBarView.swift           # Menu bar dropdown content
│   ├── Views/
│   │   ├── MainView.swift              # NavigationSplitView shell
│   │   ├── OverviewView.swift          # Status dashboard
│   │   ├── ProxiesView.swift           # Proxy groups grid
│   │   ├── ProxyGroupCard.swift        # Single group card
│   │   ├── RulesView.swift             # Rules list
│   │   ├── ConnectionsView.swift       # Connections table
│   │   ├── LogsView.swift              # Real-time logs
│   │   └── SettingsView.swift          # Settings panel
│   ├── Services/
│   │   ├── ClashAPI.swift              # REST API client (actor)
│   │   ├── ClashWebSocket.swift        # WebSocket streams
│   │   ├── SingBoxManager.swift        # sing-box lifecycle
│   │   ├── ConfigGenerator.swift       # generate.py wrapper
│   │   ├── WakeObserver.swift          # Sleep/wake recovery
│   │   └── HelperManager.swift         # XPC helper install/connection
│   ├── Models/
│   │   ├── ProxyModels.swift           # ProxyGroup, ProxyNode
│   │   ├── ConnectionModels.swift      # Connection, ConnectionSnapshot
│   │   ├── LogEntry.swift              # LogEntry
│   │   └── Rule.swift                  # Rule
│   ├── Helpers/
│   │   └── RingBuffer.swift            # Fixed-size ring buffer
│   ├── Resources/
│   │   └── Assets.xcassets/
│   │       ├── Contents.json
│   │       ├── AppIcon.appiconset/
│   │       │   └── Contents.json
│   │       ├── MenuBarIcon.imageset/
│   │       │   └── Contents.json
│   │       └── AccentColor.colorset/
│   │           └── Contents.json
│   ├── BoxX.entitlements
│   └── Info.plist
├── BoxXHelper/
│   ├── main.swift                      # XPC listener + HelperTool impl
│   ├── Info.plist
│   ├── launchd.plist
│   └── BoxXHelper.entitlements
├── Shared/
│   └── HelperProtocol.swift            # XPC protocol definition
└── Tests/
    ├── RingBufferTests.swift
    ├── ClashAPITests.swift
    └── ProxyModelsTests.swift
```

---

## Task 1: Project Scaffold + xcodegen

**Files:**
- Create: `singbox/BoxX/project.yml`
- Create: `singbox/BoxX/BoxX/BoxXApp.swift`
- Create: `singbox/BoxX/BoxX/AppState.swift`
- Create: `singbox/BoxX/BoxX/Info.plist`
- Create: `singbox/BoxX/BoxX/BoxX.entitlements`
- Create: `singbox/BoxX/BoxX/Resources/Assets.xcassets/Contents.json`
- Create: `singbox/BoxX/BoxX/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `singbox/BoxX/BoxX/Resources/Assets.xcassets/MenuBarIcon.imageset/Contents.json`
- Create: `singbox/BoxX/BoxX/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `singbox/BoxX/BoxXHelper/main.swift`
- Create: `singbox/BoxX/BoxXHelper/Info.plist`
- Create: `singbox/BoxX/BoxXHelper/launchd.plist`
- Create: `singbox/BoxX/BoxXHelper/BoxXHelper.entitlements`
- Create: `singbox/BoxX/Shared/HelperProtocol.swift`

- [ ] **Step 1: Create directory structure**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX
mkdir -p BoxX/MenuBar BoxX/Views BoxX/Services BoxX/Models BoxX/Helpers
mkdir -p BoxX/Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p BoxX/Resources/Assets.xcassets/MenuBarIcon.imageset
mkdir -p BoxX/Resources/Assets.xcassets/AccentColor.colorset
mkdir -p BoxXHelper Shared Tests
```

- [ ] **Step 2: Create project.yml for xcodegen**

```yaml
# singbox/BoxX/project.yml
name: BoxX
options:
  bundleIdPrefix: com.boxx
  deploymentTarget:
    macOS: "13.0"
  xcodeVersion: "16.0"
  generateEmptyDirectories: true

settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "13.0"

targets:
  BoxX:
    type: application
    platform: macOS
    sources:
      - path: BoxX
        excludes:
          - "**/.DS_Store"
      - path: Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.boxx.app
        INFOPLIST_FILE: BoxX/Info.plist
        CODE_SIGN_ENTITLEMENTS: BoxX/BoxX.entitlements
        ENABLE_HARDENED_RUNTIME: true
        CODE_SIGN_IDENTITY: "-"
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    dependencies:
      - target: BoxXHelper
        embed: false
        copy:
          destination: wrapper
          subpath: Contents/Library/LaunchDaemons
    postBuildScripts:
      - name: "Copy Helper launchd plist"
        script: |
          cp "${SRCROOT}/BoxXHelper/launchd.plist" "${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}/Contents/Library/LaunchDaemons/com.boxx.helper.plist"
        basedOnDependencyAnalysis: false

  BoxXHelper:
    type: tool
    platform: macOS
    sources:
      - path: BoxXHelper
        excludes:
          - "**/.DS_Store"
          - "*.plist"
      - path: Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.boxx.helper
        INFOPLIST_FILE: BoxXHelper/Info.plist
        CODE_SIGN_ENTITLEMENTS: BoxXHelper/BoxXHelper.entitlements
        ENABLE_HARDENED_RUNTIME: true
        CODE_SIGN_IDENTITY: "-"
        SKIP_INSTALL: true

  BoxXTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests
      - path: Shared
    dependencies:
      - target: BoxX
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.boxx.tests
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/BoxX.app/Contents/MacOS/BoxX"
        BUNDLE_LOADER: "$(TEST_HOST)"

schemes:
  BoxX:
    build:
      targets:
        BoxX: all
        BoxXHelper: all
        BoxXTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - BoxXTests
```

- [ ] **Step 3: Create Shared/HelperProtocol.swift**

```swift
// singbox/BoxX/Shared/HelperProtocol.swift
import Foundation

@objc protocol HelperProtocol {
    func startSingBox(configPath: String, withReply reply: @escaping (Bool, String?) -> Void)
    func stopSingBox(withReply reply: @escaping (Bool, String?) -> Void)
    func getStatus(withReply reply: @escaping (Bool, Int32) -> Void)
}

enum HelperConstants {
    static let machServiceName = "com.boxx.helper"
    static let singBoxPath = "/opt/homebrew/bin/sing-box"
}
```

- [ ] **Step 4: Create BoxXHelper/main.swift (minimal placeholder)**

```swift
// singbox/BoxX/BoxXHelper/main.swift
import Foundation

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
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(secCode, [], &info) == errSecSuccess,
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
            // Validate config path is under expected directory
            guard configPath.contains("/singbox/") && configPath.hasSuffix(".json") else {
                reply(false, "Invalid config path")
                return
            }

            guard FileManager.default.fileExists(atPath: HelperConstants.singBoxPath) else {
                reply(false, "sing-box not found at \(HelperConstants.singBoxPath)")
                return
            }

            // Stop existing process if any
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
            // Set umask so cache.db is readable by the user
            umask(0o022)

            do {
                try process.run()
                singBoxProcess = process
                // Give it a moment to start
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
                // Also try to find and kill any orphan sing-box process
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

            proc.terminate() // SIGTERM
            // Wait up to 2 seconds for graceful shutdown
            usleep(2_000_000)
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL) // actual SIGKILL, not SIGINT
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
        // Check for orphan process
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
        } // end serialQueue
    }
}

let tool = HelperTool()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = tool
listener.resume()
RunLoop.current.run()
```

- [ ] **Step 5: Create BoxXHelper plists and entitlements**

BoxXHelper/Info.plist:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.boxx.helper</string>
    <key>CFBundleName</key>
    <string>BoxXHelper</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>SMAuthorizedClients</key>
    <array>
        <string>identifier "com.boxx.app"</string>
    </array>
</dict>
</plist>
```

BoxXHelper/launchd.plist:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.boxx.helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.boxx.helper</key>
        <true/>
    </dict>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

BoxXHelper/BoxXHelper.entitlements:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

- [ ] **Step 6: Create App Info.plist and entitlements**

BoxX/Info.plist:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>BoxX</string>
    <key>CFBundleIdentifier</key>
    <string>com.boxx.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>SMPrivilegedExecutables</key>
    <dict>
        <key>com.boxx.helper</key>
        <string>identifier "com.boxx.helper"</string>
    </dict>
</dict>
</plist>
```

BoxX/BoxX.entitlements:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 7: Create Asset Catalogs**

BoxX/Resources/Assets.xcassets/Contents.json:
```json
{ "info": { "version": 1, "author": "xcode" } }
```

BoxX/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json:
```json
{ "images": [{ "idiom": "mac", "size": "512x512", "scale": "1x" }, { "idiom": "mac", "size": "512x512", "scale": "2x" }], "info": { "version": 1, "author": "xcode" } }
```

BoxX/Resources/Assets.xcassets/MenuBarIcon.imageset/Contents.json:
```json
{ "images": [{ "idiom": "universal", "scale": "1x" }, { "idiom": "universal", "scale": "2x" }], "info": { "version": 1, "author": "xcode" }, "properties": { "template-rendering-intent": "template" } }
```

BoxX/Resources/Assets.xcassets/AccentColor.colorset/Contents.json:
```json
{ "colors": [{ "idiom": "universal" }], "info": { "version": 1, "author": "xcode" } }
```

- [ ] **Step 8: Create AppState.swift**

```swift
// singbox/BoxX/BoxX/AppState.swift
import SwiftUI

@MainActor
@Observable
final class AppState {
    var isRunning = false
    var pid: Int32 = 0
    var isGenerating = false
    var generateOutput: [String] = []
    var errorMessage: String?
    var showError = false

    func showAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}
```

- [ ] **Step 9: Create BoxXApp.swift (minimal — menu bar icon + empty window)**

```swift
// singbox/BoxX/BoxX/BoxXApp.swift
import SwiftUI

@main
struct BoxXApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text("BoxX — sing-box client")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: appState.isRunning ? "network" : "network.slash")
        }

        Window("BoxX", id: "main") {
            Text("BoxX Dashboard")
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
```

- [ ] **Step 10: Generate Xcode project and verify build**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX
xcodegen generate
xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -5
```

Expected: build succeeds, app binary at `build/Debug/BoxX.app`

- [ ] **Step 11: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): scaffold Xcode project with xcodegen, app + helper targets"
```

---

## Task 2: Data Models + RingBuffer

**Files:**
- Create: `singbox/BoxX/BoxX/Models/ProxyModels.swift`
- Create: `singbox/BoxX/BoxX/Models/ConnectionModels.swift`
- Create: `singbox/BoxX/BoxX/Models/LogEntry.swift`
- Create: `singbox/BoxX/BoxX/Models/Rule.swift`
- Create: `singbox/BoxX/BoxX/Helpers/RingBuffer.swift`
- Create: `singbox/BoxX/Tests/RingBufferTests.swift`
- Create: `singbox/BoxX/Tests/ProxyModelsTests.swift`

- [ ] **Step 1: Write RingBuffer tests**

```swift
// singbox/BoxX/Tests/RingBufferTests.swift
import XCTest
@testable import BoxX

final class RingBufferTests: XCTestCase {
    func testAppendAndCount() {
        var buf = RingBuffer<Int>(capacity: 3)
        buf.append(1)
        buf.append(2)
        XCTAssertEqual(buf.count, 2)
        XCTAssertEqual(Array(buf), [1, 2])
    }

    func testOverflow() {
        var buf = RingBuffer<Int>(capacity: 3)
        buf.append(1)
        buf.append(2)
        buf.append(3)
        buf.append(4) // overflows, drops 1
        XCTAssertEqual(buf.count, 3)
        XCTAssertEqual(Array(buf), [2, 3, 4])
    }

    func testEmpty() {
        let buf = RingBuffer<String>(capacity: 5)
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(Array(buf), [])
    }

    func testRemoveAll() {
        var buf = RingBuffer<Int>(capacity: 3)
        buf.append(1)
        buf.append(2)
        buf.removeAll()
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(Array(buf), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX
xcodegen generate && xcodebuild test -scheme BoxX -configuration Debug 2>&1 | grep -E "(Test|error|FAIL|BUILD)"
```

Expected: FAIL — `RingBuffer` not defined

- [ ] **Step 3: Implement RingBuffer**

```swift
// singbox/BoxX/BoxX/Helpers/RingBuffer.swift
import Foundation

struct RingBuffer<Element>: Sequence {
    private var storage: [Element?]
    private var head = 0
    private var _count = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    var count: Int { _count }

    mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        if _count < capacity {
            _count += 1
        }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        _count = 0
    }

    func makeIterator() -> AnyIterator<Element> {
        var index = 0
        let start = _count < capacity ? 0 : head
        let total = _count
        return AnyIterator {
            guard index < total else { return nil }
            let i = (start + index) % self.capacity
            index += 1
            return self.storage[i]
        }
    }
}
```

- [ ] **Step 4: Run RingBuffer tests**

```bash
xcodebuild test -scheme BoxX -configuration Debug -only-testing:BoxXTests/RingBufferTests 2>&1 | grep -E "(Test|PASS|FAIL)"
```

Expected: all 4 tests PASS

- [ ] **Step 5: Write ProxyModels tests**

```swift
// singbox/BoxX/Tests/ProxyModelsTests.swift
import XCTest
@testable import BoxX

final class ProxyModelsTests: XCTestCase {
    func testProxyGroupDecoding() throws {
        // Actual Clash API response format for a single proxy group
        let json = """
        {
            "type": "Selector",
            "name": "Proxy",
            "udp": true,
            "history": [],
            "now": "📦SoCloud",
            "all": ["📦SoCloud", "📦良心云", "🇭🇰香港", "🇺🇸美国"]
        }
        """.data(using: .utf8)!

        let group = try JSONDecoder().decode(ProxyGroup.self, from: json)
        XCTAssertEqual(group.name, "Proxy")
        XCTAssertEqual(group.type, "Selector")
        XCTAssertEqual(group.now, "📦SoCloud")
        XCTAssertEqual(group.all.count, 4)
    }

    func testConnectionDecoding() throws {
        let json = """
        {
            "chains": ["DIRECT"],
            "download": 4530610,
            "id": "d971a0c2-fb3a-4fbb-a39d-42432dad26a4",
            "metadata": {
                "destinationIP": "183.204.92.92",
                "destinationPort": "443",
                "dnsMode": "normal",
                "host": "example.com",
                "network": "tcp",
                "processPath": "",
                "sourceIP": "172.19.0.1",
                "sourcePort": "60934",
                "type": "tun/tun-in"
            },
            "rule": "rule_set=[geosite-cn] => route(DIRECT)",
            "rulePayload": "",
            "start": "2026-03-29T10:23:19.574782+08:00",
            "upload": 68626
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conn = try decoder.decode(Connection.self, from: json)
        XCTAssertEqual(conn.id, "d971a0c2-fb3a-4fbb-a39d-42432dad26a4")
        XCTAssertEqual(conn.host, "example.com")
        XCTAssertEqual(conn.chains, ["DIRECT"])
        XCTAssertEqual(conn.download, 4530610)
    }

    func testRuleDecoding() throws {
        let json = """
        {"type": "logical", "payload": "protocol=dns || port=53", "proxy": "hijack-dns"}
        """.data(using: .utf8)!

        let rule = try JSONDecoder().decode(Rule.self, from: json)
        XCTAssertEqual(rule.type, "logical")
        XCTAssertEqual(rule.payload, "protocol=dns || port=53")
        XCTAssertEqual(rule.proxy, "hijack-dns")
    }
}
```

- [ ] **Step 6: Implement all data models**

```swift
// singbox/BoxX/BoxX/Models/ProxyModels.swift
import Foundation

struct ProxyGroup: Identifiable, Codable, Sendable {
    var id: String { name }
    let name: String
    let type: String
    let now: String?
    let all: [String]?

    var displayAll: [String] { all ?? [] }
}

struct ProxyNode: Identifiable, Codable, Sendable {
    var id: String { name }
    let name: String
    let type: String
    let history: [DelayHistory]?

    var lastDelay: Int? {
        history?.last?.delay
    }
}

struct DelayHistory: Codable, Sendable {
    let time: String
    let delay: Int
}

/// Full response from GET /proxies
struct ProxiesResponse: Codable, Sendable {
    let proxies: [String: ProxyDetail]
}

struct ProxyDetail: Codable, Sendable {
    let name: String
    let type: String
    let now: String?
    let all: [String]?
    let udp: Bool?
    let history: [DelayHistory]?
}
```

```swift
// singbox/BoxX/BoxX/Models/ConnectionModels.swift
import Foundation

struct Connection: Identifiable, Codable, Sendable {
    let id: String
    let chains: [String]
    let download: Int64
    let upload: Int64
    let metadata: ConnectionMetadata
    let rule: String
    let rulePayload: String
    let start: String

    var host: String {
        metadata.host.isEmpty ? metadata.destinationIP : metadata.host
    }

    var outbound: String {
        chains.first ?? ""
    }

    var chain: String {
        chains.joined(separator: " → ")
    }
}

struct ConnectionMetadata: Codable, Sendable {
    let destinationIP: String
    let destinationPort: String
    let dnsMode: String
    let host: String
    let network: String
    let processPath: String
    let sourceIP: String
    let sourcePort: String
    let type: String
}

struct ConnectionSnapshot: Codable, Sendable {
    let connections: [Connection]?
    let downloadTotal: Int64
    let uploadTotal: Int64
    let memory: Int64?
}
```

```swift
// singbox/BoxX/BoxX/Models/LogEntry.swift
import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let level: String
    let message: String
    let timestamp: Date

    init(level: String, message: String) {
        self.level = level
        self.message = message
        self.timestamp = Date()
    }
}

struct LogMessage: Codable, Sendable {
    let type: String   // log level
    let payload: String // message
}
```

```swift
// singbox/BoxX/BoxX/Models/Rule.swift
import Foundation

struct Rule: Identifiable, Codable, Sendable {
    let id: Int
    let type: String
    let payload: String
    let proxy: String

    enum CodingKeys: String, CodingKey {
        case type, payload, proxy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        payload = try container.decode(String.self, forKey: .payload)
        proxy = try container.decode(String.self, forKey: .proxy)
        // id assigned externally, use hash as placeholder
        id = 0
    }

    init(id: Int, type: String, payload: String, proxy: String) {
        self.id = id
        self.type = type
        self.payload = payload
        self.proxy = proxy
    }
}

struct RulesResponse: Codable, Sendable {
    let rules: [Rule]
}
```

- [ ] **Step 7: Run all model tests**

```bash
xcodegen generate && xcodebuild test -scheme BoxX -configuration Debug 2>&1 | grep -E "(Test|PASS|FAIL|BUILD)"
```

Expected: all tests PASS

- [ ] **Step 8: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add data models (ProxyGroup, Connection, LogEntry, Rule) and RingBuffer"
```

---

## Task 3: Clash API Client

**Files:**
- Create: `singbox/BoxX/BoxX/Services/ClashAPI.swift`
- Create: `singbox/BoxX/Tests/ClashAPITests.swift`

- [ ] **Step 1: Write ClashAPI tests (integration tests against running sing-box)**

```swift
// singbox/BoxX/Tests/ClashAPITests.swift
import XCTest
@testable import BoxX

/// Integration tests — require sing-box running on 127.0.0.1:9091
final class ClashAPITests: XCTestCase {
    let api = ClashAPI(baseURL: "http://127.0.0.1:9091")

    func testGetProxies() async throws {
        let groups = try await api.getProxies()
        XCTAssertFalse(groups.isEmpty, "Should return proxy groups")
        // Should contain the "Proxy" group
        XCTAssertTrue(groups.contains(where: { $0.name == "Proxy" }))
    }

    func testGetRules() async throws {
        let rules = try await api.getRules()
        XCTAssertFalse(rules.isEmpty, "Should return rules")
    }

    func testGetConnections() async throws {
        let snapshot = try await api.getConnections()
        // downloadTotal should be non-negative
        XCTAssertGreaterThanOrEqual(snapshot.downloadTotal, 0)
    }

    func testGetDelay() async throws {
        // Test delay for DIRECT which should always work
        let delay = try await api.getDelay(
            name: "DIRECT",
            url: "http://www.gstatic.com/generate_204",
            timeout: 5000
        )
        XCTAssertGreaterThan(delay, 0, "DIRECT delay should be positive")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild test -scheme BoxX -configuration Debug -only-testing:BoxXTests/ClashAPITests 2>&1 | grep -E "(Test|error|FAIL)"
```

Expected: FAIL — `ClashAPI` not defined

- [ ] **Step 3: Implement ClashAPI**

```swift
// singbox/BoxX/BoxX/Services/ClashAPI.swift
import Foundation

actor ClashAPI {
    let baseURL: String
    private let session: URLSession
    private let secret: String

    init(baseURL: String = "http://127.0.0.1:9091", secret: String = "") {
        self.baseURL = baseURL
        self.secret = secret

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:] // bypass system proxy
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - REST API

    func getProxies() async throws -> [ProxyGroup] {
        let data = try await get("/proxies")
        let response = try JSONDecoder().decode(ProxiesResponse.self, from: data)

        return response.proxies.compactMap { (_, detail) in
            guard detail.type == "Selector" || detail.type == "URLTest" || detail.type == "Fallback" else {
                return nil
            }
            return ProxyGroup(
                name: detail.name,
                type: detail.type,
                now: detail.now,
                all: detail.all
            )
        }.sorted { $0.name < $1.name }
    }

    func getProxyDetail(name: String) async throws -> ProxyDetail {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let data = try await get("/proxies/\(encoded)")
        return try JSONDecoder().decode(ProxyDetail.self, from: data)
    }

    func selectProxy(group: String, name: String) async throws {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        let body = try JSONEncoder().encode(["name": name])
        _ = try await put("/proxies/\(encoded)", body: body)
    }

    func getDelay(name: String, url: String = "http://www.gstatic.com/generate_204", timeout: Int = 5000) async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        let data = try await get("/proxies/\(encoded)/delay?url=\(encodedURL)&timeout=\(timeout)")
        let result = try JSONDecoder().decode([String: Int].self, from: data)
        return result["delay"] ?? 0
    }

    func getRules() async throws -> [Rule] {
        let data = try await get("/rules")
        let decoded = try JSONDecoder().decode(RulesResponse.self, from: data)
        return decoded.rules.enumerated().map { index, rule in
            Rule(id: index, type: rule.type, payload: rule.payload, proxy: rule.proxy)
        }
    }

    func getConnections() async throws -> ConnectionSnapshot {
        let data = try await get("/connections")
        return try JSONDecoder().decode(ConnectionSnapshot.self, from: data)
    }

    func closeConnection(id: String) async throws {
        _ = try await delete("/connections/\(id)")
    }

    func closeAllConnections() async throws {
        _ = try await delete("/connections")
    }

    func isReachable() async -> Bool {
        do {
            _ = try await get("/")
            return true
        } catch {
            return false
        }
    }

    // MARK: - HTTP Helpers

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "GET"
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func put(_ path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func delete(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "DELETE"
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClashAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func addAuth(_ request: inout URLRequest) {
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
    }
}

enum ClashAPIError: Error, LocalizedError {
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP \(code)"
        }
    }
}
```

- [ ] **Step 4: Run ClashAPI tests (requires sing-box running)**

```bash
xcodegen generate && xcodebuild test -scheme BoxX -configuration Debug -only-testing:BoxXTests/ClashAPITests 2>&1 | grep -E "(Test|PASS|FAIL)"
```

Expected: all 4 tests PASS (sing-box must be running)

- [ ] **Step 5: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add Clash REST API client with integration tests"
```

---

## Task 4: WebSocket Streams (Logs + Connections)

**Files:**
- Create: `singbox/BoxX/BoxX/Services/ClashWebSocket.swift`

- [ ] **Step 1: Implement ClashWebSocket**

```swift
// singbox/BoxX/BoxX/Services/ClashWebSocket.swift
import Foundation

final class ClashWebSocket: NSObject, @unchecked Sendable {
    private let baseURL: String
    private let secret: String
    private let lock = NSLock()
    private var _task: URLSessionWebSocketTask?
    private var _session: URLSession?

    private var task: URLSessionWebSocketTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
    private var session: URLSession? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }

    init(baseURL: String = "http://127.0.0.1:9091", secret: String = "") {
        self.baseURL = baseURL.replacingOccurrences(of: "http://", with: "ws://")
        self.secret = secret
        super.init()
    }

    func connectLogs(level: String = "info") -> AsyncStream<LogEntry> {
        AsyncStream { continuation in
            let urlString = "\(baseURL)/logs?level=\(level)"
            guard let url = URL(string: urlString) else {
                continuation.finish()
                return
            }
            var request = URLRequest(url: url)
            if !secret.isEmpty {
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config)
            let task = session.webSocketTask(with: request)
            self.session = session
            self.task = task
            task.resume()

            continuation.onTermination = { @Sendable _ in
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }

            Task { [weak self] in
                while self?.task != nil {
                    do {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            if let data = text.data(using: .utf8),
                               let log = try? JSONDecoder().decode(LogMessage.self, from: data) {
                                continuation.yield(LogEntry(level: log.type, message: log.payload))
                            }
                        case .data(let data):
                            if let log = try? JSONDecoder().decode(LogMessage.self, from: data) {
                                continuation.yield(LogEntry(level: log.type, message: log.payload))
                            }
                        @unknown default:
                            break
                        }
                    } catch {
                        continuation.finish()
                        return
                    }
                }
            }
        }
    }

    func connectConnections() -> AsyncStream<ConnectionSnapshot> {
        AsyncStream { continuation in
            let urlString = "\(baseURL)/connections"
            guard let url = URL(string: urlString) else {
                continuation.finish()
                return
            }
            var request = URLRequest(url: url)
            if !secret.isEmpty {
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config)
            let task = session.webSocketTask(with: request)
            self.session = session
            self.task = task
            task.resume()

            continuation.onTermination = { @Sendable _ in
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }

            Task { [weak self] in
                while self?.task != nil {
                    do {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            if let data = text.data(using: .utf8),
                               let snapshot = try? JSONDecoder().decode(ConnectionSnapshot.self, from: data) {
                                continuation.yield(snapshot)
                            }
                        case .data(let data):
                            if let snapshot = try? JSONDecoder().decode(ConnectionSnapshot.self, from: data) {
                                continuation.yield(snapshot)
                            }
                        @unknown default:
                            break
                        }
                    } catch {
                        continuation.finish()
                        return
                    }
                }
            }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}
```

- [ ] **Step 2: Build and verify compilation**

```bash
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add WebSocket streams for logs and connections"
```

---

## Task 5: HelperManager + SingBoxManager

**Files:**
- Create: `singbox/BoxX/BoxX/Services/HelperManager.swift`
- Create: `singbox/BoxX/BoxX/Services/SingBoxManager.swift`

- [ ] **Step 1: Implement HelperManager**

```swift
// singbox/BoxX/BoxX/Services/HelperManager.swift
import Foundation
import ServiceManagement

final class HelperManager: @unchecked Sendable {
    static let shared = HelperManager()

    private let lock = NSLock()
    private var _xpcConnection: NSXPCConnection?

    var isHelperInstalled: Bool {
        let service = SMAppService.daemon(plistName: "com.boxx.helper.plist")
        return service.status == .enabled
    }

    func installHelper() throws {
        let service = SMAppService.daemon(plistName: "com.boxx.helper.plist")
        try service.register()
    }

    func uninstallHelper() throws {
        let service = SMAppService.daemon(plistName: "com.boxx.helper.plist")
        try service.unregister()
    }

    func getProxy() -> HelperProtocol? {
        lock.lock()
        defer { lock.unlock() }

        if let connection = _xpcConnection {
            return connection.remoteObjectProxy as? HelperProtocol
        }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.interruptionHandler = {
            // Connection interrupted but can auto-recover
        }
        connection.invalidationHandler = { [weak self] in
            self?.lock.withLock { self?._xpcConnection = nil }
        }
        connection.resume()
        _xpcConnection = connection
        return connection.remoteObjectProxy as? HelperProtocol
    }

    func disconnect() {
        lock.withLock {
            _xpcConnection?.invalidate()
            _xpcConnection = nil
        }
    }
}
```

- [ ] **Step 2: Implement SingBoxManager**

```swift
// singbox/BoxX/BoxX/Services/SingBoxManager.swift
import Foundation

@MainActor
final class SingBoxManager: ObservableObject {
    static let shared = SingBoxManager()

    private let helperManager = HelperManager.shared
    private let api = ClashAPI()

    @Published var isRunning = false
    @Published var pid: Int32 = 0

    func refreshStatus() async {
        // First check via Helper
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let helper = helperManager.getProxy() else {
                self.isRunning = false
                self.pid = 0
                continuation.resume()
                return
            }
            helper.getStatus { running, pid in
                Task { @MainActor in
                    self.isRunning = running
                    self.pid = pid
                    continuation.resume()
                }
            }
        }
    }

    func start(configPath: String) async throws {
        guard let helper = helperManager.getProxy() else {
            throw SingBoxError.helperNotAvailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            helper.startSingBox(configPath: configPath) { success, error in
                if success {
                    Task { @MainActor in
                        self.isRunning = true
                        await self.refreshStatus()
                    }
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SingBoxError.startFailed(error ?? "Unknown error"))
                }
            }
        }
    }

    func stop() async throws {
        guard let helper = helperManager.getProxy() else {
            throw SingBoxError.helperNotAvailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            helper.stopSingBox { success, error in
                if success {
                    Task { @MainActor in
                        self.isRunning = false
                        self.pid = 0
                    }
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SingBoxError.stopFailed(error ?? "Unknown error"))
                }
            }
        }
    }

    func restart(configPath: String) async throws {
        try await stop()
        try await Task.sleep(for: .seconds(1))
        try await start(configPath: configPath)
    }
}

enum SingBoxError: Error, LocalizedError {
    case helperNotAvailable
    case startFailed(String)
    case stopFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotAvailable: return "Helper not installed or not running"
        case .startFailed(let msg): return "Failed to start: \(msg)"
        case .stopFailed(let msg): return "Failed to stop: \(msg)"
        }
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add HelperManager (XPC) and SingBoxManager (lifecycle)"
```

---

## Task 6: ConfigGenerator + WakeObserver

**Files:**
- Create: `singbox/BoxX/BoxX/Services/ConfigGenerator.swift`
- Create: `singbox/BoxX/BoxX/Services/WakeObserver.swift`

- [ ] **Step 1: Implement ConfigGenerator**

```swift
// singbox/BoxX/BoxX/Services/ConfigGenerator.swift
import Foundation

@MainActor
final class ConfigGenerator {
    private let scriptDir: String

    init(scriptDir: String? = nil) {
        if let dir = scriptDir {
            self.scriptDir = dir
        } else {
            // Default: find generate.py relative to the app's location
            // Assumes app is in or near the singbox directory
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
                    continuation.yield("✅ Config generation complete")
                } else {
                    continuation.yield("❌ Failed with exit code \(proc.terminationStatus)")
                }
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.yield("❌ Failed to run generate.py: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }
}
```

- [ ] **Step 2: Implement WakeObserver**

```swift
// singbox/BoxX/BoxX/Services/WakeObserver.swift
import Foundation
import AppKit

actor WakeObserver {
    private let singBoxManager: SingBoxManager
    private let api: ClashAPI
    private let configPath: String
    private var isRecovering = false
    private var observation: NSObjectProtocol?

    init(singBoxManager: SingBoxManager, api: ClashAPI, configPath: String) {
        self.singBoxManager = singBoxManager
        self.api = api
        self.configPath = configPath
    }

    func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        observation = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleWake()
            }
        }
    }

    func stopObserving() {
        if let observation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        observation = nil
    }

    private func handleWake() async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }

        // Wait for network interface to initialize
        try? await Task.sleep(for: .seconds(3))

        // Check if sing-box is running
        await singBoxManager.refreshStatus()
        let running = await singBoxManager.isRunning

        if !running {
            // Process died during sleep — restart
            try? await singBoxManager.start(configPath: configPath)
            return
        }

        // Process alive — probe connectivity
        // Step 1: Is Clash API reachable?
        let apiReachable = await api.isReachable()
        if !apiReachable {
            try? await singBoxManager.restart(configPath: configPath)
            return
        }

        // Step 2: Can we reach external network through proxy?
        let proxyWorks = await probeExternalConnectivity()
        if !proxyWorks {
            try? await singBoxManager.restart(configPath: configPath)
            return
        }

        // All good — do nothing
    }

    /// Probe external connectivity through sing-box's mixed proxy port (7890)
    private func probeExternalConnectivity() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: 7890,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort: 7890,
        ] as [String: Any]
        config.timeoutIntervalForRequest = 5

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let url = URL(string: "http://www.gstatic.com/generate_204")!
            let (_, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 204 || http.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add ConfigGenerator (generate.py wrapper) and WakeObserver (sleep/wake recovery)"
```

---

## Task 7: Menu Bar View

**Files:**
- Create: `singbox/BoxX/BoxX/MenuBar/MenuBarView.swift`
- Modify: `singbox/BoxX/BoxX/BoxXApp.swift`

- [ ] **Step 1: Implement MenuBarView**

```swift
// singbox/BoxX/BoxX/MenuBar/MenuBarView.swift
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    let singBoxManager: SingBoxManager
    let configGenerator: ConfigGenerator
    let api: ClashAPI

    @State private var proxyGroups: [ProxyGroup] = []

    var body: some View {
        // Refresh proxy groups when menu opens
        let _ = Task { await refreshGroups() }
        if appState.isRunning {
            Label("sing-box Running", systemImage: "circle.fill")
                .foregroundColor(.green)
        } else {
            Label("sing-box Stopped", systemImage: "circle")
                .foregroundColor(.secondary)
        }

        Divider()

        if appState.isRunning {
            Button("Stop") {
                Task { await stopSingBox() }
            }
        } else {
            Button("Start") {
                Task { await startSingBox() }
            }
        }

        Button("Update Subscriptions") {
            Task { await updateSubscriptions() }
        }
        .disabled(appState.isGenerating)

        if !proxyGroups.isEmpty {
            Divider()
            ForEach(proxyGroups.filter { $0.type == "Selector" }.prefix(10)) { group in
                Menu(group.name) {
                    ForEach(group.displayAll, id: \.self) { node in
                        Button {
                            Task { await selectNode(group: group.name, node: node) }
                        } label: {
                            if node == group.now {
                                Label(node, systemImage: "checkmark")
                            } else {
                                Text(node)
                            }
                        }
                    }
                }
            }
        }

        Divider()

        Button("Open Dashboard") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Settings...") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit BoxX") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func startSingBox() async {
        do {
            try await singBoxManager.start(configPath: configGenerator.configPath)
            appState.isRunning = true
        } catch {
            appState.showAlert(error.localizedDescription)
        }
    }

    private func stopSingBox() async {
        do {
            try await singBoxManager.stop()
            appState.isRunning = false
        } catch {
            appState.showAlert(error.localizedDescription)
        }
    }

    private func updateSubscriptions() async {
        appState.isGenerating = true
        for await line in configGenerator.generate() {
            appState.generateOutput.append(line)
        }
        appState.isGenerating = false
        // Restart if running
        if appState.isRunning {
            do {
                try await singBoxManager.restart(configPath: configGenerator.configPath)
            } catch {
                appState.showAlert(error.localizedDescription)
            }
        }
    }

    private func selectNode(group: String, node: String) async {
        do {
            try await api.selectProxy(group: group, name: node)
            await refreshGroups()
        } catch {
            appState.showAlert(error.localizedDescription)
        }
    }

    func refreshGroups() async {
        do {
            proxyGroups = try await api.getProxies()
        } catch {
            proxyGroups = []
        }
    }
}
```

- [ ] **Step 2: Update BoxXApp.swift with full menu bar and window integration**

```swift
// singbox/BoxX/BoxX/BoxXApp.swift
import SwiftUI

@main
struct BoxXApp: App {
    @State private var appState = AppState()
    private let singBoxManager = SingBoxManager.shared
    private let api = ClashAPI()
    private let configGenerator = ConfigGenerator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                singBoxManager: singBoxManager,
                configGenerator: configGenerator,
                api: api
            )
            .environment(appState)
            .task {
                await singBoxManager.refreshStatus()
                appState.isRunning = singBoxManager.isRunning
                appState.pid = singBoxManager.pid
            }
        } label: {
            Image(systemName: appState.isRunning ? "network" : "network.slash")
        }

        Window("BoxX", id: "main") {
            MainView(api: api, singBoxManager: singBoxManager, configGenerator: configGenerator)
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
```

- [ ] **Step 3: Create placeholder views so the app compiles**

Create minimal placeholder files for all views referenced by BoxXApp.swift that don't exist yet:

```swift
// singbox/BoxX/BoxX/Views/MainView.swift
import SwiftUI
struct MainView: View {
    let api: ClashAPI; let singBoxManager: SingBoxManager; let configGenerator: ConfigGenerator
    var body: some View { Text("Dashboard").frame(minWidth: 800, minHeight: 500) }
}
```

```swift
// singbox/BoxX/BoxX/Views/SettingsView.swift
import SwiftUI
struct SettingsView: View {
    var body: some View { Text("Settings").frame(width: 400, height: 300) }
}
```

- [ ] **Step 4: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add menu bar with start/stop, subscriptions, proxy group switching"
```

---

## Task 8: Main Window Shell + Overview

**Files:**
- Create: `singbox/BoxX/BoxX/Views/MainView.swift`
- Create: `singbox/BoxX/BoxX/Views/OverviewView.swift`

- [ ] **Step 1: Implement MainView**

```swift
// singbox/BoxX/BoxX/Views/MainView.swift
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case proxies = "Proxies"
    case rules = "Rules"
    case connections = "Connections"
    case logs = "Logs"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.bottom.50percent"
        case .proxies: return "globe"
        case .rules: return "list.bullet.rectangle"
        case .connections: return "link"
        case .logs: return "doc.text"
        }
    }
}

struct MainView: View {
    let api: ClashAPI
    let singBoxManager: SingBoxManager
    let configGenerator: ConfigGenerator
    @Environment(AppState.self) private var appState
    @State private var selection: SidebarItem = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } detail: {
            switch selection {
            case .overview:
                OverviewView(api: api, singBoxManager: singBoxManager)
            case .proxies:
                ProxiesView(api: api)
            case .rules:
                RulesView(api: api)
            case .connections:
                ConnectionsView(api: api)
            case .logs:
                LogsView()
            }
        }
    }
}
```

- [ ] **Step 2: Implement OverviewView**

```swift
// singbox/BoxX/BoxX/Views/OverviewView.swift
import SwiftUI

struct OverviewView: View {
    let api: ClashAPI
    let singBoxManager: SingBoxManager
    @Environment(AppState.self) private var appState
    @State private var connectionCount = 0
    @State private var downloadTotal: Int64 = 0
    @State private var uploadTotal: Int64 = 0
    @State private var memory: Int64 = 0
    @State private var proxyGroupCount = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Status card
                GroupBox {
                    HStack {
                        Image(systemName: appState.isRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(appState.isRunning ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(appState.isRunning ? "sing-box Running" : "sing-box Stopped")
                                .font(.title2.bold())
                            if appState.isRunning {
                                Text("PID: \(appState.pid)")
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding()
                }

                // Stats grid
                if appState.isRunning {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ], spacing: 16) {
                        StatCard(title: "Connections", value: "\(connectionCount)", icon: "link")
                        StatCard(title: "Download", value: formatBytes(downloadTotal), icon: "arrow.down.circle")
                        StatCard(title: "Upload", value: formatBytes(uploadTotal), icon: "arrow.up.circle")
                        StatCard(title: "Memory", value: formatBytes(memory), icon: "memorychip")
                    }
                }
            }
            .padding()
        }
        .task {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
    }

    private func refresh() async {
        await singBoxManager.refreshStatus()
        appState.isRunning = singBoxManager.isRunning
        appState.pid = singBoxManager.pid

        guard appState.isRunning else { return }
        do {
            let snapshot = try await api.getConnections()
            connectionCount = snapshot.connections?.count ?? 0
            downloadTotal = snapshot.downloadTotal
            uploadTotal = snapshot.uploadTotal
            memory = snapshot.memory ?? 0

            let groups = try await api.getProxies()
            proxyGroupCount = groups.count
        } catch {
            // Graceful degradation
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(value)
                    .font(.title3.monospacedDigit().bold())
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}
```

- [ ] **Step 3: Create placeholder views for remaining tabs**

Create minimal placeholder implementations so the app compiles:

```swift
// singbox/BoxX/BoxX/Views/ProxiesView.swift
import SwiftUI
struct ProxiesView: View {
    let api: ClashAPI
    var body: some View { Text("Proxies — coming soon").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
```

```swift
// singbox/BoxX/BoxX/Views/RulesView.swift
import SwiftUI
struct RulesView: View {
    let api: ClashAPI
    var body: some View { Text("Rules — coming soon").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
```

```swift
// singbox/BoxX/BoxX/Views/ConnectionsView.swift
import SwiftUI
struct ConnectionsView: View {
    let api: ClashAPI
    var body: some View { Text("Connections — coming soon").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
```

```swift
// singbox/BoxX/BoxX/Views/LogsView.swift
import SwiftUI
struct LogsView: View {
    var body: some View { Text("Logs — coming soon").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
```

```swift
// singbox/BoxX/BoxX/Views/SettingsView.swift
import SwiftUI
struct SettingsView: View {
    var body: some View { Text("Settings — coming soon").frame(width: 400, height: 300) }
}
```

- [ ] **Step 4: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add main window shell with sidebar navigation and overview dashboard"
```

---

## Task 9: Proxies View (YACD-style)

**Files:**
- Modify: `singbox/BoxX/BoxX/Views/ProxiesView.swift`
- Create: `singbox/BoxX/BoxX/Views/ProxyGroupCard.swift`

- [ ] **Step 1: Implement ProxyGroupCard**

```swift
// singbox/BoxX/BoxX/Views/ProxyGroupCard.swift
import SwiftUI

struct ProxyGroupCard: View {
    let group: ProxyGroup
    let delays: [String: Int]
    let isTesting: Bool
    let onSelect: (String) -> Void
    let onTestLatency: () -> Void

    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Text(group.name)
                        .font(.headline)
                    Text(group.type)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Spacer()
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    Button {
                        onTestLatency()
                    } label: {
                        Image(systemName: "bolt.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting)
                }

                // Current selection
                if let now = group.now {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text(now)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                // Node dots (collapsed)
                if !isExpanded {
                    HStack(spacing: 3) {
                        ForEach(group.displayAll.prefix(20), id: \.self) { node in
                            Circle()
                                .fill(node == group.now ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                        if group.displayAll.count > 20 {
                            Text("+\(group.displayAll.count - 20)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Expanded node list
                if isExpanded {
                    Divider()
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(group.displayAll, id: \.self) { node in
                            Button {
                                onSelect(node)
                            } label: {
                                HStack {
                                    Image(systemName: node == group.now ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(node == group.now ? .accentColor : .secondary)
                                        .font(.caption)
                                    Text(node)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    if let delay = delays[node] {
                                        Text(delay > 0 ? "\(delay)ms" : "timeout")
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(delayColor(delay))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .red }
        if delay < 200 { return .green }
        if delay < 500 { return .yellow }
        return .red
    }
}
```

- [ ] **Step 2: Implement full ProxiesView**

```swift
// singbox/BoxX/BoxX/Views/ProxiesView.swift
import SwiftUI

struct ProxiesView: View {
    let api: ClashAPI
    @State private var groups: [ProxyGroup] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var delays: [String: [String: Int]] = [:] // group -> node -> delay
    @State private var testingGroup: String?

    private var filteredGroups: [ProxyGroup] {
        if searchText.isEmpty { return groups }
        return groups.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search groups...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            if isLoading && groups.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ], spacing: 12) {
                        ForEach(filteredGroups) { group in
                            ProxyGroupCard(
                                group: group,
                                delays: delays[group.name] ?? [:],
                                isTesting: testingGroup == group.name,
                                onSelect: { node in
                                    Task { await selectNode(group: group.name, node: node) }
                                },
                                onTestLatency: {
                                    Task { await testGroupLatency(group: group) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        isLoading = true
        do {
            groups = try await api.getProxies()
        } catch {
            groups = []
        }
        isLoading = false
    }

    private func selectNode(group: String, node: String) async {
        do {
            try await api.selectProxy(group: group, name: node)
            await refresh()
        } catch {
            // silent fail
        }
    }

    private func testGroupLatency(group: ProxyGroup) async {
        testingGroup = group.name
        for node in group.displayAll {
            do {
                let delay = try await api.getDelay(name: node)
                delays[group.name, default: [:]][node] = delay
            } catch {
                delays[group.name, default: [:]][node] = 0
            }
        }
        testingGroup = nil
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add ProxiesView with YACD-style group cards, node switching, latency testing"
```

---

## Task 10: Rules, Connections, Logs Views

**Files:**
- Modify: `singbox/BoxX/BoxX/Views/RulesView.swift`
- Modify: `singbox/BoxX/BoxX/Views/ConnectionsView.swift`
- Modify: `singbox/BoxX/BoxX/Views/LogsView.swift`

- [ ] **Step 1: Implement RulesView**

```swift
// singbox/BoxX/BoxX/Views/RulesView.swift
import SwiftUI

struct RulesView: View {
    let api: ClashAPI
    @State private var rules: [Rule] = []
    @State private var isLoading = false
    @State private var searchText = ""

    private var filteredRules: [Rule] {
        if searchText.isEmpty { return rules }
        return rules.filter {
            $0.payload.localizedCaseInsensitiveContains(searchText) ||
            $0.proxy.localizedCaseInsensitiveContains(searchText) ||
            $0.type.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search rules...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("\(filteredRules.count) rules")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding()

            Table(filteredRules) {
                TableColumn("#") { rule in
                    Text("\(rule.id)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .width(40)

                TableColumn("Type") { rule in
                    Text(rule.type)
                        .font(.caption)
                }
                .width(80)

                TableColumn("Payload") { rule in
                    Text(rule.payload)
                        .font(.caption)
                        .lineLimit(1)
                        .help(rule.payload)
                }

                TableColumn("Proxy") { rule in
                    Text(rule.proxy)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .width(150)
            }
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        isLoading = true
        do {
            rules = try await api.getRules()
        } catch {
            rules = []
        }
        isLoading = false
    }
}
```

- [ ] **Step 2: Implement ConnectionsView**

```swift
// singbox/BoxX/BoxX/Views/ConnectionsView.swift
import SwiftUI

struct ConnectionsView: View {
    let api: ClashAPI
    @State private var connections: [Connection] = []
    @State private var downloadTotal: Int64 = 0
    @State private var uploadTotal: Int64 = 0
    @State private var searchText = ""
    @State private var ws: ClashWebSocket?
    @State private var streamTask: Task<Void, Never>?

    private var filteredConnections: [Connection] {
        if searchText.isEmpty { return connections }
        return connections.filter {
            $0.host.localizedCaseInsensitiveContains(searchText) ||
            $0.rule.localizedCaseInsensitiveContains(searchText) ||
            $0.outbound.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search connections...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("\(filteredConnections.count) connections")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Spacer()

                Text("↓\(formatBytes(downloadTotal)) ↑\(formatBytes(uploadTotal))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)

                Button("Close All") {
                    Task {
                        try? await api.closeAllConnections()
                    }
                }
                .font(.caption)
            }
            .padding()

            Table(filteredConnections.prefix(500)) {
                TableColumn("Host") { conn in
                    Text(conn.host)
                        .font(.caption)
                        .lineLimit(1)
                        .help(conn.host)
                }

                TableColumn("Rule") { conn in
                    Text(conn.rule)
                        .font(.caption)
                        .lineLimit(1)
                        .help(conn.rule)
                }
                .width(200)

                TableColumn("Outbound") { conn in
                    Text(conn.outbound)
                        .font(.caption)
                }
                .width(100)

                TableColumn("Chain") { conn in
                    Text(conn.chain)
                        .font(.caption)
                        .lineLimit(1)
                }
                .width(150)

                TableColumn("↓") { conn in
                    Text(formatBytes(conn.download))
                        .font(.caption.monospacedDigit())
                }
                .width(70)

                TableColumn("↑") { conn in
                    Text(formatBytes(conn.upload))
                        .font(.caption.monospacedDigit())
                }
                .width(70)
            }
        }
        .task {
            startStreaming()
        }
        .onDisappear {
            stopStreaming()
        }
    }

    private func startStreaming() {
        let websocket = ClashWebSocket()
        ws = websocket
        streamTask = Task {
            for await snapshot in websocket.connectConnections() {
                connections = snapshot.connections ?? []
                downloadTotal = snapshot.downloadTotal
                uploadTotal = snapshot.uploadTotal
            }
        }
    }

    private func stopStreaming() {
        streamTask?.cancel()
        ws?.disconnect()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
```

- [ ] **Step 3: Implement LogsView**

```swift
// singbox/BoxX/BoxX/Views/LogsView.swift
import SwiftUI

struct LogsView: View {
    @State private var logs = RingBuffer<LogEntry>(capacity: 1000)
    @State private var levelFilter = "info"
    @State private var ws: ClashWebSocket?
    @State private var streamTask: Task<Void, Never>?
    @State private var autoScroll = true

    private let levels = ["debug", "info", "warning", "error"]

    var body: some View {
        VStack(spacing: 0) {
            // Level filter
            HStack {
                ForEach(levels, id: \.self) { level in
                    Button(level) {
                        levelFilter = level
                        restartStream()
                    }
                    .buttonStyle(.bordered)
                    .tint(level == levelFilter ? .accentColor : .secondary)
                }

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .font(.caption)

                Button("Clear") {
                    logs.removeAll()
                }
            }
            .padding()

            ScrollViewReader { proxy in
                List(Array(logs), id: \.id) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.level.prefix(4).uppercased())
                            .font(.caption.monospaced().bold())
                            .foregroundColor(levelColor(entry.level))
                            .frame(width: 40, alignment: .leading)

                        Text(entry.timestamp, style: .time)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)

                        Text(entry.message)
                            .font(.caption)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .id(entry.id)
                }
                .onChange(of: logs.count) {
                    if autoScroll, let last = Array(logs).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .task {
            startStream()
        }
        .onDisappear {
            stopStream()
        }
    }

    private func startStream() {
        let websocket = ClashWebSocket()
        ws = websocket
        streamTask = Task {
            for await entry in websocket.connectLogs(level: levelFilter) {
                logs.append(entry)
            }
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        ws?.disconnect()
    }

    private func restartStream() {
        stopStream()
        logs.removeAll()
        startStream()
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "debug": return .secondary
        case "info": return .blue
        case "warning": return .orange
        case "error": return .red
        default: return .primary
        }
    }
}
```

- [ ] **Step 4: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add Rules, Connections, and Logs views with real-time WebSocket streaming"
```

---

## Task 11: Settings View + Launch at Login

**Files:**
- Modify: `singbox/BoxX/BoxX/Views/SettingsView.swift`

- [ ] **Step 1: Implement SettingsView**

```swift
// singbox/BoxX/BoxX/Views/SettingsView.swift
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("singBoxPath") private var singBoxPath = "/opt/homebrew/bin/sing-box"
    @AppStorage("scriptDir") private var scriptDir = ""
    @State private var launchAtLogin = false
    @State private var helperInstalled = false
    @State private var helperStatus = ""

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }

            Section("Paths") {
                LabeledContent("sing-box") {
                    TextField("", text: $singBoxPath)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Script directory") {
                    HStack {
                        TextField("", text: $scriptDir)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                scriptDir = url.path
                            }
                        }
                    }
                }
            }

            Section("Privileged Helper") {
                LabeledContent("Status") {
                    HStack {
                        Image(systemName: helperInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(helperInstalled ? .green : .red)
                        Text(helperInstalled ? "Installed" : "Not installed")
                    }
                }
                if !helperInstalled {
                    Button("Install Helper") {
                        installHelper()
                    }
                } else {
                    Button("Reinstall Helper") {
                        reinstallHelper()
                    }
                }
                if !helperStatus.isEmpty {
                    Text(helperStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 350)
        .onAppear {
            refreshState()
        }
    }

    private func refreshState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        helperInstalled = HelperManager.shared.isHelperInstalled

        if scriptDir.isEmpty {
            // Auto-detect
            let home = NSHomeDirectory()
            let candidate = "\(home)/Documents/Dev/myspace/xx_script/singbox"
            if FileManager.default.fileExists(atPath: "\(candidate)/generate.py") {
                scriptDir = candidate
            }
        }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            appState.showAlert("Failed to update login item: \(error.localizedDescription)")
            launchAtLogin = !enabled // revert
        }
    }

    private func installHelper() {
        do {
            try HelperManager.shared.installHelper()
            helperInstalled = true
            helperStatus = "Helper installed successfully"
        } catch {
            helperStatus = "Install failed: \(error.localizedDescription)"
        }
    }

    private func reinstallHelper() {
        do {
            try HelperManager.shared.uninstallHelper()
            try HelperManager.shared.installHelper()
            helperInstalled = true
            helperStatus = "Helper reinstalled successfully"
        } catch {
            helperStatus = "Reinstall failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): add Settings view with launch at login, paths config, helper management"
```

---

## Task 12: Wire Up WakeObserver + Final Integration

**Files:**
- Modify: `singbox/BoxX/BoxX/BoxXApp.swift`

- [ ] **Step 1: Update BoxXApp.swift to wire WakeObserver on launch**

```swift
// singbox/BoxX/BoxX/BoxXApp.swift
import SwiftUI

@main
struct BoxXApp: App {
    @State private var appState = AppState()
    private let singBoxManager = SingBoxManager.shared
    private let api = ClashAPI()
    private let configGenerator = ConfigGenerator()
    @State private var wakeObserver: WakeObserver?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                singBoxManager: singBoxManager,
                configGenerator: configGenerator,
                api: api
            )
            .environment(appState)
            .task {
                await singBoxManager.refreshStatus()
                appState.isRunning = singBoxManager.isRunning
                appState.pid = singBoxManager.pid

                // Start wake observer
                let observer = WakeObserver(
                    singBoxManager: singBoxManager,
                    api: api,
                    configPath: configGenerator.configPath
                )
                await observer.startObserving()
                wakeObserver = observer
            }
        } label: {
            Image(systemName: appState.isRunning ? "network" : "network.slash")
        }

        Window("BoxX", id: "main") {
            MainView(api: api, singBoxManager: singBoxManager, configGenerator: configGenerator)
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
                .alert("Error", isPresented: Binding(
                    get: { appState.showError },
                    set: { appState.showError = $0 }
                )) {
                    Button("OK") { appState.showError = false }
                } message: {
                    Text(appState.errorMessage ?? "Unknown error")
                }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
```

- [ ] **Step 2: Run full build**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Run all tests**

```bash
xcodebuild test -scheme BoxX -configuration Debug 2>&1 | grep -E "(Test|PASS|FAIL|BUILD)"
```

Expected: all tests PASS

- [ ] **Step 4: Manual smoke test**

```bash
# Open the built app
open $(xcodebuild -scheme BoxX -configuration Debug -showBuildSettings 2>/dev/null | grep " BUILT_PRODUCTS_DIR" | awk '{print $3}')/BoxX.app
```

Verify:
1. Menu bar icon appears
2. Clicking icon shows dropdown menu
3. Dashboard window opens via "Open Dashboard"
4. Proxies tab shows proxy groups (if sing-box running)
5. Connections tab streams live data
6. Logs tab streams live logs

- [ ] **Step 5: Commit**

```bash
git add singbox/BoxX/
git commit -m "feat(BoxX): wire WakeObserver, error alerts, final integration"
```

---

## Task 13: Clean Up + Final Verification

- [ ] **Step 1: Add .gitignore entries for build artifacts**

Append to `singbox/BoxX/.gitignore`:
```
build/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
DerivedData/
.DS_Store
```

- [ ] **Step 2: Run full clean build**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/BoxX
xcodegen generate && xcodebuild -scheme BoxX -configuration Debug clean build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Run all tests**

```bash
xcodebuild test -scheme BoxX -configuration Debug 2>&1 | grep -E "(Test|PASS|FAIL|BUILD)"
```

Expected: all tests PASS

- [ ] **Step 4: Final commit**

```bash
git add singbox/BoxX/ .gitignore
git commit -m "chore(BoxX): add .gitignore, clean build verification"
```

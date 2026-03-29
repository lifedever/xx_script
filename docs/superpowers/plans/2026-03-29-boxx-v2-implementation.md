# BoxX v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign BoxX as a Surge-inspired macOS native client for sing-box, with Swift-native config management, XPC privileged helper, and subscription parsing.

**Architecture:** Config-centric design where `config.json` is the single source of truth for user-editable settings, `proxies/*.json` stores subscription nodes separately, and `runtime-config.json` merges both for sing-box. Four layers: Views (SwiftUI) → ConfigEngine (Codable + FSEvents) → Services (subscription/rules) → Helper (XPC/SMAppService).

**Tech Stack:** Swift 6.0, SwiftUI, SwiftData, XPC, SMAppService, macOS 14.0+, xcodegen

**Spec:** `docs/superpowers/specs/2026-03-29-boxx-v2-design.md`

**Base path:** `singbox/BoxX/` (all relative paths below are from this root)

---

## File Structure

### New Files

```
BoxX/Models/
├── JSONValue.swift              — Recursive JSON enum (string/number/bool/null/array/object)
├── SingBoxConfig.swift          — Top-level config Codable struct
├── OutboundConfig.swift         — Outbound enum (selector/urltest/vmess/ss/trojan/hysteria2/vless/unknown)
├── InboundConfig.swift          — Inbound Codable struct
├── RouteConfig.swift            — RouteConfig + RouteRule + RuleSet Codable structs
├── DNSConfig.swift              — DNS Codable structs
├── ExperimentalConfig.swift     — Experimental (Clash API) Codable struct
├── LogConfig.swift              — Log Codable struct
├── ParsedProxy.swift            — Parsed subscription node model
└── BuiltinRuleSet.swift         — Built-in rule set definitions

BoxX/Services/
├── ConfigEngine.swift           — Core: load/save/watch config.json, merge runtime
├── FileWatcher.swift            — FSEvents wrapper with debounce
├── XPCClient.swift              — XPC connection to Helper, async wrappers
├── SubscriptionService.swift    — Orchestrates fetch→parse→group→save→deploy pipeline
├── SubscriptionFetcher.swift    — Download subscription URLs
├── ClashYAMLParser.swift        — Parse Clash YAML subscription format
├── SingBoxJSONParser.swift      — Parse sing-box JSON subscription format
├── AutoGrouper.swift            — Auto-group nodes by region/subscription
└── RuleSetManager.swift         — Download/cache/update remote rule sets

BoxX/SwiftData/
└── DataModels.swift             — SwiftData models (Subscription, UserRuleSetConfig, AppPreference)

Tests/
├── JSONValueTests.swift         — JSONValue encode/decode round-trip
├── ConfigEngineTests.swift      — Config load/save/merge round-trip with real config.json
├── ClashYAMLParserTests.swift   — Parse real Clash YAML subscription data
├── SingBoxJSONParserTests.swift — Parse real sing-box JSON subscription data
└── AutoGrouperTests.swift       — Region keyword matching
```

### Modified Files

```
Shared/HelperProtocol.swift      — Add reload, flushDNS, setSystemProxy, clearSystemProxy
BoxXHelper/main.swift            — Add new methods, update path validation
BoxX/BoxXApp.swift               — Replace SingBoxManager with XPCClient, add SwiftData container
BoxX/Models/AppState.swift       — Expand with ConfigEngine state
BoxX/Services/WakeObserver.swift — Replace SingBoxManager calls with XPCClient
BoxX/Views/MainView.swift        — Surge-style sidebar
BoxX/Views/OverviewView.swift    — Dashboard cards
BoxX/Views/ProxiesView.swift     — Card-based proxy groups
BoxX/Views/ConnectionsView.swift — 8-column table + detail panel
BoxX/Views/RulesView.swift       — Surge-style rule table (full rewrite)
BoxX/MenuBar/MenuBarView.swift   — Surge-style with group titles
BoxX/Views/SubscriptionsView.swift — Adapt for Swift-native parser
BoxX/Views/SettingsView.swift    — Add "Open Config Directory"
project.yml                      — Add SwiftData framework, new files
```

### Deleted Files

```
BoxX/Services/ConfigGenerator.swift    — Replaced by ConfigEngine
BoxX/Services/SingBoxManager.swift     — Replaced by XPCClient
BoxX/Services/SubscriptionManager.swift — Replaced by SwiftData + SubscriptionService
BoxX/Services/RuleManager.swift        — Replaced by ConfigEngine + RuleSetManager
BoxX/Services/ServiceConfigManager.swift — Replaced by ConfigEngine rule management
BoxX/Views/ServicesConfigView.swift    — Replaced by rule management in RulesView
BoxX/Views/RuleTestView.swift         — Merged into ConnectionsView "Add Rule" flow
```

---

## Phase 1: Foundation — JSONValue + Codable Models

### Task 1: JSONValue Recursive Enum

**Files:**
- Create: `BoxX/Models/JSONValue.swift`
- Create: `Tests/JSONValueTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/JSONValueTests.swift
import XCTest
@testable import BoxX

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let json = """
        {"string":"hello","number":42,"float":3.14,"bool":true,"null":null,"array":[1,"two"],"object":{"nested":true}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(JSONValue.self, from: json)
        let encoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(JSONValue.self, from: encoded)

        XCTAssertEqual(decoded, redecoded)
    }

    func testAccessors() throws {
        let value = JSONValue.object([
            "name": .string("test"),
            "port": .number(8080),
            "enabled": .bool(true)
        ])

        XCTAssertEqual(value["name"]?.stringValue, "test")
        XCTAssertEqual(value["port"]?.numberValue, 8080)
        XCTAssertEqual(value["enabled"]?.boolValue, true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd singbox/BoxX && xcodegen generate && xcodebuild test -scheme BoxX -destination 'platform=macOS' -only-testing BoxXTests/JSONValueTests 2>&1 | tail -20`
Expected: FAIL — `JSONValue` not found

- [ ] **Step 3: Implement JSONValue**

```swift
// BoxX/Models/JSONValue.swift
import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    // MARK: - Accessors

    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    var numberValue: Double? {
        guard case .number(let n) = self else { return nil }
        return n
    }

    var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let a) = self else { return nil }
        return a
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let o) = self else { return nil }
        return o
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd singbox/BoxX && xcodegen generate && xcodebuild test -scheme BoxX -destination 'platform=macOS' -only-testing BoxXTests/JSONValueTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add BoxX/Models/JSONValue.swift Tests/JSONValueTests.swift
git commit -m "feat(BoxX): add JSONValue recursive enum for unknown field preservation"
```

---

### Task 2: Outbound Codable Model

**Files:**
- Create: `BoxX/Models/OutboundConfig.swift`

This is the most complex Codable type — polymorphic enum dispatching on `type` field, with `.unknown` fallback.

- [ ] **Step 1: Write the test** (add to `Tests/ConfigEngineTests.swift`, create file)

```swift
// Tests/ConfigEngineTests.swift
import XCTest
@testable import BoxX

final class OutboundConfigTests: XCTestCase {
    func testDecodeSelectorOutbound() throws {
        let json = """
        {"type":"selector","tag":"Proxy","outbounds":["node1","node2"],"default":"node1"}
        """.data(using: .utf8)!

        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .selector(let s) = outbound else {
            XCTFail("Expected selector"); return
        }
        XCTAssertEqual(s.tag, "Proxy")
        XCTAssertEqual(s.outbounds, ["node1", "node2"])
    }

    func testDecodeVMessOutbound() throws {
        let json = """
        {"type":"vmess","tag":"HK-01","server":"example.com","server_port":443,"uuid":"test-uuid","alter_id":0,"security":"auto"}
        """.data(using: .utf8)!

        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .vmess(let v) = outbound else {
            XCTFail("Expected vmess"); return
        }
        XCTAssertEqual(v.tag, "HK-01")
        XCTAssertEqual(v.server, "example.com")
    }

    func testDecodeUnknownOutbound() throws {
        let json = """
        {"type":"wireguard","tag":"wg0","server":"1.2.3.4","private_key":"abc"}
        """.data(using: .utf8)!

        let outbound = try JSONDecoder().decode(Outbound.self, from: json)
        guard case .unknown(let tag, let type, _) = outbound else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(tag, "wg0")
        XCTAssertEqual(type, "wireguard")
    }

    func testOutboundRoundTrip() throws {
        let json = """
        {"type":"vmess","tag":"test","server":"x.com","server_port":443,"uuid":"u","alter_id":0,"security":"auto","extra_field":"preserved"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Outbound.self, from: json)
        let encoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(Outbound.self, from: encoded)

        // Verify unknown fields are preserved
        guard case .vmess(let v) = redecoded else { XCTFail("Expected vmess"); return }
        XCTAssertEqual(v.unknownFields["extra_field"]?.stringValue, "preserved")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement OutboundConfig.swift**

Implement `Outbound` enum with cases: `.direct`, `.selector`, `.urltest`, `.vmess`, `.shadowsocks`, `.trojan`, `.hysteria2`, `.vless`, `.unknown`. Each associated struct has known fields + `var unknownFields: [String: JSONValue]`. Custom `init(from:)` reads `type` field first, then dispatches to the right struct. See spec Section 2 for field definitions.

**Important:** Add a computed property `var tag: String` on `Outbound` that extracts the tag from whichever case it is (each associated struct has a `tag` field, `.unknown` has it directly). This is used by `buildRuntimeConfig()` and UI code.

Key implementation detail: each outbound struct's `init(from:)` must iterate all keys in the `KeyedDecodingContainer`, decode known keys normally, and collect unknown keys into `unknownFields`.

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add BoxX/Models/OutboundConfig.swift Tests/ConfigEngineTests.swift
git commit -m "feat(BoxX): add Outbound Codable enum with unknown field preservation"
```

---

### Task 3: Remaining Config Codable Models

**Files:**
- Create: `BoxX/Models/SingBoxConfig.swift`
- Create: `BoxX/Models/InboundConfig.swift`
- Create: `BoxX/Models/RouteConfig.swift`
- Create: `BoxX/Models/DNSConfig.swift`
- Create: `BoxX/Models/ExperimentalConfig.swift`
- Create: `BoxX/Models/LogConfig.swift`

All follow the same pattern: known fields + `unknownFields: [String: JSONValue]` with custom `init(from:)`/`encode(to:)`.

- [ ] **Step 1: Write round-trip test with real config.json**

```swift
// Add to Tests/ConfigEngineTests.swift
final class SingBoxConfigTests: XCTestCase {
    func testRealConfigRoundTrip() throws {
        // Copy singbox/config.json to Tests/Fixtures/config.json as a test fixture
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/config.json")
        let data = try Data(contentsOf: fixtureURL)

        let config = try JSONDecoder().decode(SingBoxConfig.self, from: data)

        // Verify key structures loaded
        XCTAssertFalse(config.outbounds.isEmpty)
        XCTAssertFalse(config.inbounds.isEmpty)
        XCTAssertNotNil(config.route)
        XCTAssertNotNil(config.dns)

        // Round-trip: encode and decode again
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(config)
        let redecoded = try JSONDecoder().decode(SingBoxConfig.self, from: encoded)

        // Verify outbound count preserved
        XCTAssertEqual(config.outbounds.count, redecoded.outbounds.count)
        // Verify route rules count preserved
        XCTAssertEqual(config.route.rules?.count, redecoded.route.rules?.count)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement all config model files**

Reference the actual `singbox/config.json` to understand the real structure. Each struct needs:
- Known fields with proper `CodingKeys` (sing-box uses `snake_case`)
- `var unknownFields: [String: JSONValue] = [:]`
- Custom `init(from:)` and `encode(to:)` for unknown field preservation

`SingBoxConfig` is the top-level struct tying everything together:
```swift
struct SingBoxConfig: Codable {
    var log: LogConfig?
    var dns: DNSConfig?
    var inbounds: [Inbound]
    var outbounds: [Outbound]
    var route: RouteConfig
    var experimental: ExperimentalConfig?
    var unknownFields: [String: JSONValue] = [:]
}
```

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add BoxX/Models/SingBoxConfig.swift BoxX/Models/InboundConfig.swift BoxX/Models/RouteConfig.swift BoxX/Models/DNSConfig.swift BoxX/Models/ExperimentalConfig.swift BoxX/Models/LogConfig.swift Tests/ConfigEngineTests.swift
git commit -m "feat(BoxX): add complete SingBoxConfig Codable models with round-trip test"
```

---

### Task 4: ConfigEngine — Load, Save, Merge

**Files:**
- Create: `BoxX/Services/ConfigEngine.swift`

- [ ] **Step 1: Write the tests**

```swift
// Add to Tests/ConfigEngineTests.swift
final class ConfigEngineLoadSaveTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadAndSave() throws {
        // Copy real config to temp dir
        let realConfig = URL(fileURLWithPath: "/Users/gefangshuai/Documents/Dev/myspace/xx_script/singbox/config.json")
        let tempConfig = tempDir.appendingPathComponent("config.json")
        try FileManager.default.copyItem(at: realConfig, to: tempConfig)

        let engine = ConfigEngine(baseDir: tempDir)
        try engine.load()

        XCTAssertFalse(engine.config.outbounds.isEmpty)

        // Save and verify file exists
        try engine.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempConfig.path))
    }

    func testMergeProxies() throws {
        // Create minimal config.json (no proxy nodes, just selectors)
        let coreConfig = """
        {"outbounds":[{"type":"selector","tag":"Proxy","outbounds":["DIRECT"]},{"type":"direct","tag":"DIRECT"}],"inbounds":[],"route":{"rules":[]}}
        """
        let configPath = tempDir.appendingPathComponent("config.json")
        try coreConfig.data(using: .utf8)!.write(to: configPath)

        // Create proxies directory with one subscription
        let proxiesDir = tempDir.appendingPathComponent("proxies")
        try FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)
        let proxyNodes = """
        [{"type":"vmess","tag":"HK-01","server":"a.com","server_port":443,"uuid":"u","alter_id":0,"security":"auto"}]
        """
        try proxyNodes.data(using: .utf8)!.write(to: proxiesDir.appendingPathComponent("TestSub.json"))

        let engine = ConfigEngine(baseDir: tempDir)
        try engine.load()

        // Build runtime config should merge proxy nodes into outbounds
        let runtime = engine.buildRuntimeConfig()
        let tags = runtime.outbounds.map { $0.tag }
        XCTAssertTrue(tags.contains("HK-01"))
        XCTAssertTrue(tags.contains("Proxy"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement ConfigEngine**

```swift
// BoxX/Services/ConfigEngine.swift
import Foundation
import Observation

@Observable
class ConfigEngine {
    private(set) var config: SingBoxConfig
    private(set) var proxies: [String: [Outbound]] = [:]  // key = subscription name

    let baseDir: URL
    private var configURL: URL { baseDir.appendingPathComponent("config.json") }
    private var proxiesDir: URL { baseDir.appendingPathComponent("proxies") }
    private var runtimeURL: URL { baseDir.appendingPathComponent("runtime-config.json") }
    private var lastMtime: Date?

    init(baseDir: URL) {
        self.config = SingBoxConfig(inbounds: [], outbounds: [], route: RouteConfig())
        self.baseDir = baseDir
    }

    func load() throws {
        // Load core config
        let data = try Data(contentsOf: configURL)
        config = try JSONDecoder().decode(SingBoxConfig.self, from: data)
        lastMtime = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date

        // Load proxy files
        proxies = [:]
        if FileManager.default.fileExists(atPath: proxiesDir.path) {
            let files = try FileManager.default.contentsOfDirectory(at: proxiesDir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                let name = file.deletingPathExtension().lastPathComponent
                let proxyData = try Data(contentsOf: file)
                let nodes = try JSONDecoder().decode([Outbound].self, from: proxyData)
                proxies[name] = nodes
            }
        }
    }

    func save() throws {
        // Mtime conflict check: if file was externally modified since last load, reload first
        if let currentMtime = try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date,
           let lastMtime, currentMtime > lastMtime {
            try load()  // Reload external changes first
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
        lastMtime = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date
    }

    func buildRuntimeConfig() -> SingBoxConfig {
        var runtime = config
        // Append all proxy nodes from subscriptions
        let allProxyNodes = proxies.values.flatMap { $0 }
        runtime.outbounds.append(contentsOf: allProxyNodes)
        return runtime
    }

    var onDeployComplete: (() async -> Void)?  // Set by App to call XPCClient.reload()

    func deployRuntime() async throws {
        let runtime = buildRuntimeConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(runtime)
        try data.write(to: runtimeURL, options: .atomic)
        // Notify Helper to reload sing-box with new runtime config
        await onDeployComplete?()
    }

    func saveProxies(name: String, nodes: [Outbound]) throws {
        try FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(nodes)
        try data.write(to: proxiesDir.appendingPathComponent("\(name).json"), options: .atomic)
        proxies[name] = nodes
    }

    func removeProxies(name: String) throws {
        let file = proxiesDir.appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        proxies.removeValue(forKey: name)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add BoxX/Services/ConfigEngine.swift Tests/ConfigEngineTests.swift
git commit -m "feat(BoxX): add ConfigEngine with load/save/merge runtime config"
```

---

### Task 5: FileWatcher — FSEvents with Debounce

**Files:**
- Create: `BoxX/Services/FileWatcher.swift`

- [ ] **Step 1: Implement FileWatcher**

```swift
// BoxX/Services/FileWatcher.swift
import Foundation

final class FileWatcher {
    private let path: String
    private let callback: () -> Void
    private let debounceInterval: TimeInterval
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?

    init(path: String, debounceInterval: TimeInterval = 0.5, callback: @escaping () -> Void) {
        self.path = path
        self.callback = callback
        self.debounceInterval = debounceInterval
    }

    func start() { /* Create FSEventStream for path, on change call debounced callback via DispatchWorkItem */ }
    func stop() { /* Invalidate and release stream, cancel pending debounce */ }
}
```

Full implementation: create `FSEventStreamCreate` watching the directory containing config.json, set `kFSEventStreamCreateFlagFileEvents`. On event, cancel any pending debounce task, schedule new one with `Task.sleep(for: .milliseconds(500))` then call callback.

- [ ] **Step 2: Add startWatching/stopWatching to ConfigEngine**

```swift
// Add to ConfigEngine
private var watcher: FileWatcher?

func startWatching() {
    watcher = FileWatcher(path: configURL.deletingLastPathComponent().path) { [weak self] in
        Task { @MainActor in
            try? self?.load()
        }
    }
    watcher?.start()
}

func stopWatching() {
    watcher?.stop()
    watcher = nil
}
```

- [ ] **Step 3: Build to verify no compiler errors**

Run: `cd singbox/BoxX && xcodegen generate && xcodebuild build -scheme BoxX -destination 'platform=macOS' 2>&1 | tail -10`

- [ ] **Step 4: Commit**

```bash
git add BoxX/Services/FileWatcher.swift BoxX/Services/ConfigEngine.swift
git commit -m "feat(BoxX): add FileWatcher with FSEvents debounce for config.json monitoring"
```

---

## Phase 2: XPC Helper Spike

> **Important:** This is the highest-risk task. Spike it independently before proceeding. See spec Section 3 for details on SMAppService requirements.

### Task 6: Update HelperProtocol

**Files:**
- Modify: `Shared/HelperProtocol.swift`

- [ ] **Step 1: Add new methods to HelperProtocol**

Add `reloadSingBox`, `flushDNS`, `setSystemProxy`, `clearSystemProxy` to the existing `@objc protocol HelperProtocol`. Keep the existing method signatures unchanged. See spec Section 3 for exact signatures.

- [ ] **Step 2: Build to verify compilation**

- [ ] **Step 3: Commit**

```bash
git add Shared/HelperProtocol.swift
git commit -m "feat(BoxX): extend HelperProtocol with reload, flushDNS, systemProxy methods"
```

---

### Task 7: Update BoxXHelper Implementation

**Files:**
- Modify: `BoxXHelper/main.swift`

- [ ] **Step 1: Update path validation**

Change `configPath.contains("/singbox/")` to also accept `/Library/Application Support/BoxX/`.

- [ ] **Step 2: Implement reloadSingBox**

Send `SIGHUP` to managed sing-box process via `kill(pid, SIGHUP)`.

- [ ] **Step 3: Implement flushDNS**

Execute `dscacheutil -flushcache` and `killall -HUP mDNSResponder` (Helper runs as root, so these work).

- [ ] **Step 4: Implement setSystemProxy / clearSystemProxy**

Use `networksetup -setwebproxy` / `-setsecurewebproxy` / `-setsocksfirewallproxy` for set, and the corresponding `-setXXXproxystate off` for clear.

- [ ] **Step 5: Build and test Helper target**

Run: `cd singbox/BoxX && xcodegen generate && xcodebuild build -scheme BoxXHelper -destination 'platform=macOS' 2>&1 | tail -10`

- [ ] **Step 6: Commit**

```bash
git add BoxXHelper/main.swift
git commit -m "feat(BoxX): update Helper with reload, flushDNS, systemProxy support"
```

---

### Task 8: XPCClient — App-Side XPC Wrapper

**Files:**
- Create: `BoxX/Services/XPCClient.swift`

- [ ] **Step 1: Implement XPCClient**

```swift
// BoxX/Services/XPCClient.swift
import Foundation
import ServiceManagement

actor XPCClient {
    private var connection: NSXPCConnection?

    func register() throws {
        try SMAppService.daemon(plistName: "com.boxx.helper.plist").register()
    }

    private func getConnection() -> NSXPCConnection {
        if let conn = connection { return conn }
        let conn = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { await self?.handleDisconnect() }
        }
        conn.resume()
        connection = conn
        return conn
    }

    private func handleDisconnect() { connection = nil }

    // Each method wraps the callback-based XPC call with withCheckedContinuation
    func start(configPath: String) async throws -> (Bool, String?) {
        let proxy = getConnection().remoteObjectProxyWithErrorHandler { _ in } as! HelperProtocol
        return await withCheckedContinuation { cont in
            proxy.startSingBox(configPath: configPath) { success, error in
                cont.resume(returning: (success, error))
            }
        }
    }

    func stop() async throws -> (Bool, String?) { /* same pattern */ }
    func reload() async throws -> (Bool, String?) { /* same pattern, calls reloadSingBox */ }
    func getStatus() async throws -> (Bool, Int32) { /* same pattern */ }
    func flushDNS() async throws -> Bool { /* same pattern */ }
    func setSystemProxy(port: Int32) async throws -> Bool { /* same pattern */ }
    func clearSystemProxy() async throws -> Bool { /* same pattern */ }
}
```

Each method wraps the callback-based XPC call with `withCheckedContinuation`.

- [ ] **Step 2: Build to verify compilation**

- [ ] **Step 3: Commit**

```bash
git add BoxX/Services/XPCClient.swift
git commit -m "feat(BoxX): add XPCClient async wrapper for Helper communication"
```

---

### Task 9: SMAppService Spike Verification

This is a manual verification step. The spike needs actual code signing and system-level testing.

- [ ] **Step 1: Update project.yml**

Ensure post-build script copies Helper binary and plist to `Contents/Library/LaunchDaemons/`.

- [ ] **Step 2: Build and install the app**

Run: `cd singbox/BoxX && ./box.sh build` (or the xcodebuild equivalent)

- [ ] **Step 3: Test SMAppService registration**

Launch the app, verify the system authorization dialog appears, and the Helper registers as a LaunchDaemon.

- [ ] **Step 4: Test XPC communication**

Verify `XPCClient.start()` successfully launches sing-box via the Helper.

- [ ] **Step 5: Document results**

If the spike succeeds, commit. If it fails, document the issue and adjust the approach (may need to fall back to `box.sh` temporarily while fixing signing).

```bash
git commit -m "spike(BoxX): verify SMAppService + XPC helper registration"
```

---

## Phase 3: Subscription Parser

### Task 10: ParsedProxy Model + SingBoxJSONParser

**Files:**
- Create: `BoxX/Models/ParsedProxy.swift`
- Create: `BoxX/Services/SingBoxJSONParser.swift`
- Create: `Tests/SingBoxJSONParserTests.swift`

- [ ] **Step 1: Write the test**

Use a sample of real sing-box JSON subscription output (capture one from a real subscription URL, save as test fixture in `Tests/Fixtures/singbox-subscription.json`).

```swift
func testParseSingBoxJSON() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/singbox-subscription.json")
    let data = try Data(contentsOf: fixtureURL)
    let parser = SingBoxJSONParser()
    XCTAssertTrue(parser.canParse(data))
    let nodes = try parser.parse(data)
    XCTAssertFalse(nodes.isEmpty)
    // Verify first node has expected fields
    XCTAssertFalse(nodes[0].tag.isEmpty)
    XCTAssertFalse(nodes[0].server.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement ParsedProxy and SingBoxJSONParser**

`SingBoxJSONParser.canParse()`: try decode as JSON, check if it's an object with `"outbounds"` key or an array of objects with `"type"` field.

`SingBoxJSONParser.parse()`: decode outbound objects, map to `ParsedProxy` + convert to `Outbound` enum for storage.

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add BoxX/Models/ParsedProxy.swift BoxX/Services/SingBoxJSONParser.swift Tests/SingBoxJSONParserTests.swift Tests/Fixtures/
git commit -m "feat(BoxX): add sing-box JSON subscription parser"
```

---

### Task 11: ClashYAMLParser

**Files:**
- Create: `BoxX/Services/ClashYAMLParser.swift`
- Create: `Tests/ClashYAMLParserTests.swift`

- [ ] **Step 1: Write the test** with real Clash YAML subscription data (save as `Tests/Fixtures/clash-subscription.yaml`)

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement ClashYAMLParser**

`canParse()`: check if data starts with YAML indicators (`proxies:` key). Parse YAML manually (simple line-by-line parser for the `proxies:` section — Clash YAML proxy format is relatively flat). Convert each proxy entry to `ParsedProxy` → `Outbound`.

Supported types: vmess, ss, trojan, hysteria2, vless. Map Clash field names to sing-box field names.

Reference `generate.py` lines for the field mapping (e.g., Clash `cipher` → sing-box `security`, Clash `alterId` → sing-box `alter_id`).

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add BoxX/Services/ClashYAMLParser.swift Tests/ClashYAMLParserTests.swift
git commit -m "feat(BoxX): add Clash YAML subscription parser"
```

---

### Task 12: SubscriptionFetcher + AutoGrouper

**Files:**
- Create: `BoxX/Services/SubscriptionFetcher.swift`
- Create: `BoxX/Services/AutoGrouper.swift`
- Create: `Tests/AutoGrouperTests.swift`

- [ ] **Step 1: Write AutoGrouper tests**

```swift
func testGroupByRegion() {
    let nodes = [
        makeNode(tag: "🇭🇰 香港 01"), makeNode(tag: "HK-02"),
        makeNode(tag: "🇯🇵 日本 01"), makeNode(tag: "JP-Tokyo"),
        makeNode(tag: "🇺🇸 US-01"), makeNode(tag: "Random Node")
    ]
    let groups = AutoGrouper.groupByRegion(nodes)
    XCTAssertTrue(groups.keys.contains("🇭🇰 香港"))
    XCTAssertTrue(groups.keys.contains("🇯🇵 日本"))
    XCTAssertTrue(groups.keys.contains("🇺🇸 美国"))
    XCTAssertTrue(groups.keys.contains("🌐 其他"))
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement SubscriptionFetcher and AutoGrouper**

`SubscriptionFetcher`: simple `URLSession.shared.data(from: url)` with User-Agent header and retry logic.

`AutoGrouper`: keyword matching for regions (港/HK/Hong Kong → 香港, 日/JP/Japan → 日本, etc.). Reference `generate.py`'s region detection logic. Return `[String: [String]]` mapping group name → node tags.

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add BoxX/Services/SubscriptionFetcher.swift BoxX/Services/AutoGrouper.swift Tests/AutoGrouperTests.swift
git commit -m "feat(BoxX): add SubscriptionFetcher and AutoGrouper"
```

---

### Task 12.5: SubscriptionService — End-to-End Orchestration

**Files:**
- Create: `BoxX/Services/SubscriptionService.swift`

- [ ] **Step 1: Implement SubscriptionService**

```swift
// BoxX/Services/SubscriptionService.swift
import Foundation

class SubscriptionService {
    let configEngine: ConfigEngine
    let fetcher = SubscriptionFetcher()
    private let parsers: [any ProxyParser] = [SingBoxJSONParser(), ClashYAMLParser()]
    let grouper = AutoGrouper()

    init(configEngine: ConfigEngine) {
        self.configEngine = configEngine
    }

    func updateSubscription(name: String, url: URL) async throws -> Int {
        // 1. Fetch
        let data = try await fetcher.fetch(url: url)

        // 2. Parse (try each parser)
        guard let parser = parsers.first(where: { $0.canParse(data) }) else {
            throw SubscriptionError.unsupportedFormat
        }
        let nodes = try parser.parse(data)

        // 3. Convert ParsedProxy → [Outbound]
        let outbounds = nodes.map { $0.toOutbound() }

        // 4. Save to proxies/{name}.json
        try configEngine.saveProxies(name: name, nodes: outbounds)

        // 5. Auto-group and update selector outbound references in config
        let groups = grouper.groupByRegion(outbounds)
        updateSelectorGroups(with: groups, subscriptionName: name)

        // 6. Deploy runtime config
        try await configEngine.deployRuntime()

        return nodes.count
    }

    private func updateSelectorGroups(with groups: [String: [String]], subscriptionName: String) {
        // For each region group, find or create a selector outbound in config
        // Add new node tags to the selector's outbounds list
        // Ensures subscription nodes are referenced by strategy groups
    }
}
```

This service layer keeps business logic out of the view. `SubscriptionsView` calls `subscriptionService.updateSubscription()` and shows progress.

- [ ] **Step 2: Build to verify compilation**

- [ ] **Step 3: Commit**

```bash
git add BoxX/Services/SubscriptionService.swift
git commit -m "feat(BoxX): add SubscriptionService orchestration layer"
```

---

### Task 13: SwiftData Models + Subscription Import Flow

**Files:**
- Create: `BoxX/SwiftData/DataModels.swift`

- [ ] **Step 0: Update project.yml for SwiftData**

Add `SwiftData` to the `BoxX` target's frameworks list in `project.yml`. Run `xcodegen generate` to update the Xcode project.

- [ ] **Step 1: Implement SwiftData models**

`Subscription`, `UserRuleSetConfig`, `AppPreference` per spec Section 1. Add v1 migration: on first launch, check for `subscriptions.json` at the old path, import entries into SwiftData.

- [ ] **Step 2: Wire into BoxXApp.swift**

Add `.modelContainer(for: [Subscription.self, UserRuleSetConfig.self, AppPreference.self])` to the App scene.

- [ ] **Step 3: Build to verify compilation**

- [ ] **Step 4: Commit**

```bash
git add BoxX/SwiftData/DataModels.swift BoxX/BoxXApp.swift
git commit -m "feat(BoxX): add SwiftData models with v1 subscription migration"
```

---

## Phase 4: Rule Management

### Task 14: Built-in Rule Sets + RuleSetManager

**Files:**
- Create: `BoxX/Models/BuiltinRuleSet.swift`
- Create: `BoxX/Services/RuleSetManager.swift`

- [ ] **Step 1: Define built-in rule sets**

Reference `generate.py`'s service definitions. Define structs for: AI, Google, YouTube, Netflix, Disney, TikTok, Microsoft, Notion, Apple. Each has an ID, display name, geosite rules, and default outbound.

- [ ] **Step 2: Implement RuleSetManager**

Handles downloading remote rule set files, caching to `rules/` directory, and checking for updates based on configured intervals.

- [ ] **Step 3: Build to verify compilation**

- [ ] **Step 4: Commit**

```bash
git add BoxX/Models/BuiltinRuleSet.swift BoxX/Services/RuleSetManager.swift
git commit -m "feat(BoxX): add built-in rule sets and RuleSetManager"
```

---

## Phase 5: App Wiring + Core UI

### Task 15: Update BoxXApp.swift — Replace SingBoxManager with XPCClient

**Files:**
- Modify: `BoxX/BoxXApp.swift`
- Modify: `BoxX/Models/AppState.swift`
- Delete: `BoxX/Services/SingBoxManager.swift`
- Delete: `BoxX/Services/ConfigGenerator.swift`

- [ ] **Step 1: Expand AppState**

Add `configEngine: ConfigEngine`, `xpcClient: XPCClient`, `proxyMode: ProxyMode` to AppState. Remove `isGenerating`.

- [ ] **Step 2: Update BoxXApp.swift**

Replace `SingBoxManager` init with `XPCClient` + `ConfigEngine` init. Set `baseDir` to `/Library/Application Support/BoxX/`. Load config on startup. Replace `StatusPoller` to use XPC `getStatus` instead of Clash API reachability check.

- [ ] **Step 3: Delete old files**

Remove `SingBoxManager.swift` and `ConfigGenerator.swift`.

- [ ] **Step 4: Build to verify compilation** (views will have errors — fix with stubs if needed)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(BoxX): replace SingBoxManager with XPCClient + ConfigEngine"
```

---

### Task 16: Update WakeObserver

**Files:**
- Modify: `BoxX/Services/WakeObserver.swift`

- [ ] **Step 1: Replace SingBoxManager calls with XPCClient**

Change `singBoxManager.restart()` → `xpcClient.reload()`, `flushDNS()` → `xpcClient.flushDNS()`, `closeAllConnections()` → `clashAPI.closeAllConnections()`.

- [ ] **Step 2: Build to verify**

- [ ] **Step 3: Commit**

```bash
git add BoxX/Services/WakeObserver.swift
git commit -m "refactor(BoxX): update WakeObserver to use XPCClient"
```

---

### Task 17: MainView — Surge-Style Sidebar

**Files:**
- Modify: `BoxX/Views/MainView.swift`

- [ ] **Step 1: Redesign sidebar**

Surge-style narrow sidebar with icon + text labels. Tabs: 概览, 策略组, 规则, 请求, 日志, 订阅, 设置. Remove v1's Services/RuleTest tabs. Use `NavigationSplitView` with a fixed-width sidebar.

- [ ] **Step 2: Build and visually verify**

- [ ] **Step 3: Commit**

```bash
git add BoxX/Views/MainView.swift
git commit -m "refactor(BoxX): Surge-style sidebar navigation"
```

---

### Task 18: OverviewView — Dashboard Redesign

**Files:**
- Modify: `BoxX/Views/OverviewView.swift`

- [ ] **Step 1: Redesign with stat cards**

Status card (running/stopped), connections count, proxy mode, download/upload speed in a grid layout. Wire to AppState + ClashAPI.

- [ ] **Step 2: Build and visually verify**

- [ ] **Step 3: Commit**

```bash
git add BoxX/Views/OverviewView.swift
git commit -m "refactor(BoxX): Surge-style dashboard overview"
```

---

### Task 19: ProxiesView — Card-Based Groups

**Files:**
- Modify: `BoxX/Views/ProxiesView.swift`

- [ ] **Step 1: Redesign with card grid**

Two-column `LazyVGrid`. Cards grouped by section (服务分流 / 地区节点 / 订阅分组) with section headers. Each card shows: group name, type badge (select/url-test), current node with delay indicator (green/yellow/red), node count. Click card to expand node list. Data from Clash API `getProxies()`.

**Dual-write on node switch:** When user selects a different node, call both `clashAPI.selectProxy()` (immediate effect) and `configEngine.selectProxy()` (persist to config.json). Same pattern as MenuBarView.

- [ ] **Step 2: Build and visually verify**

- [ ] **Step 3: Commit**

```bash
git add BoxX/Views/ProxiesView.swift
git commit -m "refactor(BoxX): card-based proxy group view"
```

---

### Task 20: ConnectionsView — 8-Column Table + Detail Panel

**Files:**
- Modify: `BoxX/Views/ConnectionsView.swift`
- Delete: `BoxX/Views/RuleTestView.swift`

- [ ] **Step 1: Redesign table**

8 columns: 时间, 主机, 协议, 规则, 出站, 链路, ↓, ↑. Default sort by time descending. TCP blue, UDP yellow. DIRECT bold. Delay indicators on outbound column.

- [ ] **Step 2: Add detail panel**

Right-side panel shown on row click. Shows: time, host, destination IP, protocol, rule match path (step-by-step), rule set, outbound chain (tree view), traffic, duration. Action buttons: Add Rule, Disconnect.

- [ ] **Step 3: Add toolbar**

Search field, Pause/Resume, Clear, Disconnect All buttons.

- [ ] **Step 4: Build and visually verify**

- [ ] **Step 5: Commit**

```bash
git add BoxX/Views/ConnectionsView.swift
git rm BoxX/Views/RuleTestView.swift
git commit -m "refactor(BoxX): 8-column request viewer with detail panel"
```

---

### Task 21: RulesView — Full Rewrite

**Files:**
- Modify: `BoxX/Views/RulesView.swift`
- Modify: `BoxX/Views/AddRuleSheet.swift`
- Delete: `BoxX/Views/ServicesConfigView.swift`

- [ ] **Step 1: Implement rule table**

Surge-style table with columns: type, match content, strategy group, enabled toggle. Data from ConfigEngine (config.route.rules). Support drag-to-reorder (changes rule priority). Show hit counts from Clash API connection matching.

- [ ] **Step 2: Implement rule set management section**

Below the table: list of built-in rule sets (toggle enable/disable) and remote rule sets (add URL, update interval). Data from SwiftData `UserRuleSetConfig` + `BuiltinRuleSet` definitions.

- [ ] **Step 3: Update AddRuleSheet**

Keep the modal, ensure it writes through ConfigEngine.addRule() → config.json.

- [ ] **Step 4: Build and visually verify**

- [ ] **Step 5: Commit**

```bash
git add BoxX/Views/RulesView.swift BoxX/Views/AddRuleSheet.swift
git rm BoxX/Views/ServicesConfigView.swift
git commit -m "refactor(BoxX): Surge-style rule management with rule sets"
```

---

### Task 22: MenuBarView — Surge-Style with Group Titles

**Files:**
- Modify: `BoxX/MenuBar/MenuBarView.swift`

- [ ] **Step 1: Redesign menu structure**

Top: status + mode selector. Then three sections with headers (服务分流 / 地区节点 / 订阅分组). Each group row: left = emoji + name, right = current node name + ▸. Click opens submenu to select node. Bottom: Update Subscriptions, Open Config Directory, Show Main Window, Quit.

Node selection calls both Clash API (immediate) and ConfigEngine (persist).

- [ ] **Step 2: Build and visually verify**

- [ ] **Step 3: Commit**

```bash
git add BoxX/MenuBar/MenuBarView.swift
git commit -m "refactor(BoxX): Surge-style menu bar with group titles"
```

---

### Task 23: SubscriptionsView — Swift-Native Parser

**Files:**
- Modify: `BoxX/Views/SubscriptionsView.swift`

- [ ] **Step 1: Adapt for SwiftData + new parser**

Replace `SubscriptionManager` JSON file access with SwiftData `@Query`. "Save and Update" button now: fetch via `SubscriptionFetcher`, parse via parser chain, auto-group via `AutoGrouper`, save nodes via `ConfigEngine.saveProxies()`, update strategy group references in config, deploy runtime config.

Show progress via native `ProgressView` instead of log text stream.

- [ ] **Step 2: Build and visually verify**

- [ ] **Step 3: Commit**

```bash
git add BoxX/Views/SubscriptionsView.swift
git commit -m "refactor(BoxX): adapt subscriptions view for Swift-native parser"
```

---

### Task 24: SettingsView — Add Open Config Directory

**Files:**
- Modify: `BoxX/Views/SettingsView.swift`

- [ ] **Step 1: Add "Open Config Directory" button**

`NSWorkspace.shared.open(configEngine.baseDir)` — opens `/Library/Application Support/BoxX/` in Finder. Also keep launch-at-login toggle.

- [ ] **Step 2: Build and visually verify**

- [ ] **Step 3: Commit**

```bash
git add BoxX/Views/SettingsView.swift
git commit -m "feat(BoxX): add 'Open Config Directory' to settings"
```

---

## Phase 6: Integration + Polish

### Task 25: Update project.yml

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add new files to targets**

Add all new Swift files to the `BoxX` target sources. Add SwiftData framework. Remove deleted files. Update test target with new test files.

- [ ] **Step 2: Generate and build**

Run: `cd singbox/BoxX && xcodegen generate && xcodebuild build -scheme BoxX -destination 'platform=macOS' 2>&1 | tail -20`

- [ ] **Step 3: Commit**

```bash
git add project.yml
git commit -m "chore(BoxX): update project.yml for v2 file structure"
```

---

### Task 26: Delete Obsolete Files + Update Localization

**Files:**
- Delete: `BoxX/Services/SubscriptionManager.swift`
- Delete: `BoxX/Services/RuleManager.swift`
- Delete: `BoxX/Services/ServiceConfigManager.swift`
- Modify: `BoxX/Resources/en.lproj/Localizable.strings`
- Modify: `BoxX/Resources/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: Remove obsolete service files**

```bash
git rm BoxX/Services/SubscriptionManager.swift BoxX/Services/RuleManager.swift BoxX/Services/ServiceConfigManager.swift
```

- [ ] **Step 2: Update localization strings**

Remove keys for deleted views (ServicesConfig, RuleTest). Add keys for new sidebar items and UI labels.

- [ ] **Step 3: Build and verify**

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(BoxX): remove obsolete v1 files, update localization"
```

---

### Task 27: End-to-End Smoke Test

Manual verification of the full flow.

- [ ] **Step 1: Build and install**

```bash
cd singbox/BoxX && xcodegen generate && xcodebuild build -scheme BoxX -destination 'platform=macOS'
```

- [ ] **Step 2: First launch — verify Helper registration**

Launch app, verify SMAppService authorization dialog, verify Helper installs.

- [ ] **Step 3: Import subscriptions**

Add a subscription URL, verify nodes are fetched, parsed, saved to `proxies/`, auto-grouped, and displayed in strategy groups.

- [ ] **Step 4: Start sing-box**

Click start, verify sing-box launches via XPC Helper with `runtime-config.json`.

- [ ] **Step 5: Verify all views**

Walk through each tab: Overview (status/stats), Proxies (cards with node switching), Rules (table with rule sets), Requests (8-column live stream + detail panel), Logs (live stream), Subscriptions (management), Settings (open config dir).

- [ ] **Step 6: Test config hot-reload**

Manually edit `/Library/Application Support/BoxX/config.json` in a text editor. Verify App detects the change and reloads within 1 second.

- [ ] **Step 7: Test menu bar**

Verify group titles, node names, switching nodes from menu bar.

- [ ] **Step 8: Fix any issues found, commit**

```bash
git commit -m "fix(BoxX): address smoke test issues"
```

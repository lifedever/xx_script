# BoxX — sing-box macOS Native Client

## Overview

BoxX is a native macOS menu bar app that wraps the sing-box CLI, providing a GUI equivalent to the YACD web dashboard with automatic sleep/wake recovery. It communicates with sing-box via the Clash API (`127.0.0.1:9091`) and manages the sing-box process through a Privileged Helper.

**Minimum system requirement**: macOS 13 Ventura (SMAppService)

**Source location**: `singbox/BoxX/`

## Architecture

```
┌─────────────────────────────────────────────────┐
│  BoxX.app (user space)                          │
│                                                 │
│  ┌───────────┐  ┌────────────┐  ┌────────────┐ │
│  │ MenuBar   │  │ MainWindow │  │ WakeObserver│ │
│  │ Manager   │  │ (SwiftUI)  │  │            │ │
│  └─────┬─────┘  └─────┬──────┘  └─────┬──────┘ │
│        │              │               │         │
│        ▼              ▼               ▼         │
│  ┌─────────────────────────────────────────┐    │
│  │         ClashAPI (HTTP/WebSocket)       │    │
│  │         127.0.0.1:9091                  │    │
│  └─────────────────┬───────────────────────┘    │
│                    │                            │
│  ┌─────────────────┴───────────────────────┐    │
│  │     SingBoxManager                      │    │
│  │     - XPC → Helper (start/stop only)    │    │
│  │     - Process → generate.py             │    │
│  └─────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
         │ XPC
         ▼
┌─────────────────────────────────────────────────┐
│  com.boxx.helper (LaunchDaemon, root)           │
│                                                 │
│  - startSingBox(configPath: String)             │
│  - stopSingBox()                                │
│                                                 │
│  Nothing else. No network, no DNS, no routing.  │
└─────────────────────────────────────────────────┘
         │ Process
         ▼
┌─────────────────────────────────────────────────┐
│  sing-box run -c config.json                    │
│  (TUN mode, manages own network stack)          │
│  Clash API on 127.0.0.1:9091                    │
│  Node selections persisted in cache.db          │
└─────────────────────────────────────────────────┘
```

## Project Structure

```
singbox/BoxX/
├── BoxX.xcodeproj
├── BoxX/                              # Main App target
│   ├── BoxXApp.swift                  # App entry, MenuBarExtra + Window
│   ├── MenuBar/
│   │   └── MenuBarManager.swift       # Menu bar icon, dropdown menu
│   ├── Views/
│   │   ├── MainView.swift             # NavigationSplitView with sidebar
│   │   ├── OverviewView.swift         # Status, uptime, node count
│   │   ├── ProxiesView.swift          # Proxy group cards (YACD-style)
│   │   ├── ProxyGroupCard.swift       # Single group card component
│   │   ├── RulesView.swift            # Rule list
│   │   ├── ConnectionsView.swift      # Active connections table
│   │   ├── LogsView.swift             # Real-time log stream
│   │   └── SettingsView.swift         # Settings (launch at login, etc.)
│   ├── Services/
│   │   ├── ClashAPI.swift             # Clash REST API client
│   │   ├── ClashWebSocket.swift       # WebSocket for logs/connections
│   │   ├── SingBoxManager.swift       # sing-box lifecycle (via XPC)
│   │   ├── ConfigGenerator.swift      # Calls generate.py
│   │   ├── WakeObserver.swift         # Sleep/wake detection + auto-fix
│   │   └── HelperManager.swift        # Helper install/XPC connection
│   ├── Models/
│   │   ├── ProxyGroup.swift           # Proxy group model
│   │   ├── ProxyNode.swift            # Node model
│   │   ├── Connection.swift           # Connection model
│   │   └── LogEntry.swift             # Log entry model
│   ├── Helpers/
│   │   └── RingBuffer.swift           # Ring buffer for log entries
│   └── Assets.xcassets
├── BoxXHelper/                        # Privileged Helper target
│   ├── main.swift                     # XPC listener entry point
│   ├── HelperDelegate.swift           # NSXPCListenerDelegate
│   ├── HelperTool.swift               # Implementation of HelperProtocol
│   ├── Info.plist
│   └── launchd.plist
└── Shared/
    └── HelperProtocol.swift           # XPC protocol (shared)
```

## Module Specifications

### 1. Privileged Helper (`BoxXHelper`)

**Responsibility**: Start and stop the sing-box process. Nothing else.

**XPC Protocol**:
```swift
@objc protocol HelperProtocol {
    func startSingBox(configPath: String, reply: @escaping (Bool, String?) -> Void)
    func stopSingBox(reply: @escaping (Bool, String?) -> Void)
    func getStatus(reply: @escaping (Bool, Int32) -> Void)  // running?, pid
}
```

**Security**:
- Helper validates XPC caller's code signature before executing any operation (`SecCodeCopySigningInformation`), only accepts connections from BoxX.app
- `startSingBox` validates `configPath` is under the user's singbox script directory (rejects arbitrary paths)
- sing-box binary path is hardcoded to the full absolute path (`/usr/local/bin/sing-box`), not resolved via PATH

**Installation**:
- Uses `SMAppService.daemon(plistName:)` (macOS 13+)
- First launch: detect helper not installed → system authorization prompt (one-time password)
- Helper registered as LaunchDaemon, auto-restarts on crash
- Required entitlements and plist keys:
  - App: `com.apple.developer.embedded-content` entitlement
  - Helper: embedded in `Contents/Library/LaunchDaemons/` with matching `launchd.plist`
  - Helper Info.plist: `SMAuthorizedClients` with app's signing identifier
  - App Info.plist: `SMPrivilegedExecutables` with helper's signing identifier

**Process management**:
- Start: `Process()` with full path `/usr/local/bin/sing-box run -c <configPath>`
- Environment: minimal, explicit PATH set to `/usr/local/bin:/usr/bin:/bin`
- Stop: `SIGTERM` → wait 2s → `SIGKILL` fallback
- Helper holds process reference, cleans up on exit

**File ownership**: sing-box runs as root and writes `cache.db`. To avoid permission issues, Helper sets `umask(0o022)` before starting sing-box, and the config specifies `cache.db` path in a shared-writable location. Alternatively, Helper runs `chown` on `cache.db` back to the user after sing-box starts.

**App launch with existing sing-box**: On launch, `SingBoxManager` calls `getStatus()`. If sing-box is already running, it attaches (uses Clash API directly) without starting a new instance.

**XPC reliability**:
- `interruptionHandler`: log warning, connection auto-recovers
- `invalidationHandler`: reconnect on next operation
- 10-second timeout per call

**Constraints**:
- Does NOT modify system proxy settings
- Does NOT modify routing table
- Does NOT flush DNS
- Does NOT make any network requests
- Does NOT listen on any port (only XPC)

### 2. Menu Bar (`MenuBarManager`)

**Implementation**: `MenuBarExtra` with `Menu` content (not custom view — uses native NSMenu rendering for reliability).

**Menu structure**:
```
● sing-box Running (green) / ○ Stopped (gray)
──────────────────
▶ Start / ■ Stop
↻ Update Subscriptions
──────────────────
Proxy        → [submenu: subscription groups + regions]
🤖OpenAI     → [submenu: subscription groups + regions]
...other service groups
──────────────────
Open Dashboard
Settings...
──────────────────
Quit BoxX
```

**Proxy group submenus**:
- Show service groups (those returned by Clash API with type "selector")
- Each submenu lists the group's direct outbounds (subscription groups, region groups, etc.)
- Groups identified by their Clash API data, not by emoji prefix parsing
- Current selection shown with checkmark
- Switching calls `PUT /proxies/{name}` via Clash API

**State updates**:
- Refresh on menu open (not polling)
- Status icon color reflects sing-box process state

### 3. Main Window

**Layout**: `NavigationSplitView` with fixed sidebar, 5 sections.

#### 3.1 Overview (`OverviewView`)
- sing-box running status + uptime
- Total node count, active connections count
- Current mode (Rule/Global/Direct)
- Data from: `GET /` and `GET /connections`

#### 3.2 Proxies (`ProxiesView`)
- `LazyVGrid` of proxy group cards (2 columns)
- Each card shows: group name, type, current selection, node dots
- Expand card: show all nodes with latency, click to switch
- Lightning button: test latency for all nodes in group (`GET /proxies/{name}/delay`)
- Search bar: filter groups by name
- Data from: `GET /proxies`
- Switch node: `PUT /proxies/{name}` with `{"name": "node-tag"}`

**Performance**:
- `LazyVGrid` — only renders visible cards
- Latency test results cached in `@State`, not persisted
- Debounce: latency test button disabled for 2s after click

#### 3.3 Rules (`RulesView`)
- `List` of rules with type, payload, proxy columns
- Data from: `GET /rules`
- Static data, fetched once on tab switch

#### 3.4 Connections (`ConnectionsView`)
- `Table` (macOS native) with columns: Host, Rule, Outbound, Chain, Download, Upload
- Real-time via WebSocket (`/connections`)
- Search bar: filter by host/rule/outbound
- Close connection: `DELETE /connections/{id}`
- Max display: 500 rows, most recent first

**Performance**:
- Native `Table` — virtualized rendering
- WebSocket pushes full connection snapshots (not diffs); app diffs locally to update UI efficiently
- Filter runs on cached data, no re-fetch

#### 3.5 Logs (`LogsView`)
- Real-time via WebSocket (`/logs?level=info`)
- Level filter buttons: debug / info / warning / error
- Ring buffer: max 1000 entries, oldest auto-discarded
- Auto-scroll to bottom, pause on manual scroll up

**Performance**:
- `RingBuffer<LogEntry>` — fixed memory, O(1) insert
- `List` with `id` — SwiftUI diffs efficiently
- No persistence — logs lost on tab switch (intentional, keeps it simple)

#### 3.6 Settings (`SettingsView`)
- Launch at login toggle (`SMAppService.mainApp.register/unregister`)
- sing-box binary path (default: `/usr/local/bin/sing-box`)
- Config file path (default: `<appBundlePath>/../../../singbox/config.json`, falling back to user selection)
- Subscriptions file path
- Helper status (installed/not installed) + reinstall button
- Settings stored in `UserDefaults` via `@AppStorage`

### 4. Clash API Client (`ClashAPI`)

**Implementation**: `actor` with `URLSession` for REST, `URLSessionWebSocketTask` for WebSocket.

```swift
actor ClashAPI {
    private let baseURL = "http://127.0.0.1:9091"
    private let session: URLSession  // non-proxy session, direct connection

    // REST
    func getProxies() async throws -> [ProxyGroup]
    func selectProxy(group: String, name: String) async throws
    func getDelay(name: String, url: String, timeout: Int) async throws -> Int
    func getRules() async throws -> [Rule]
    func getConnections() async throws -> ConnectionSnapshot
    func closeConnection(id: String) async throws
    func closeAllConnections() async throws

    // WebSocket
    func connectLogs(level: String) -> AsyncStream<LogEntry>
    func connectConnections() -> AsyncStream<ConnectionSnapshot>
}
```

**Key details**:
- URLSession configured with `ProxyConfiguration.none` — must not route through sing-box proxy port
- Supports `Authorization: Bearer <secret>` header if configured (default: empty secret, no auth needed)
- Connection is local (127.0.0.1), timeout 5 seconds
- All methods are async, no blocking
- WebSocket auto-reconnects on disconnect with 2s delay

### 5. Sleep/Wake Recovery (`WakeObserver`)

**Trigger**: `NSWorkspace.shared.notificationCenter` → `.didWakeNotification`

**Flow**:
```
didWakeNotification received
  → wait 3 seconds (network interface initialization)
  → check: is sing-box process alive? (via Helper getStatus)
      → NO → start sing-box, done
      → YES → probe connectivity:
          1. GET http://127.0.0.1:9091 (Clash API, timeout 3s)
             → fail → restart sing-box, done
          2. GET http://www.gstatic.com/generate_204 through 127.0.0.1:7890 proxy port (timeout 5s)
             This intentionally goes through sing-box's mixed proxy port to test outbound connectivity.
             → fail → restart sing-box, done
          3. both pass → do nothing, done
```

**Constraints**:
- Does NOT call any Clash API to switch nodes
- Does NOT regenerate config
- Does NOT flush DNS
- Restart = stop + start same config → sing-box reads cache.db → same nodes as before
- Only one recovery in-flight at a time (guard via `actor` isolation, not a bare `Bool`)

### 6. Config Generator (`ConfigGenerator`)

**Implementation**: Calls existing `generate.py` via `Process`.

```swift
class ConfigGenerator {
    func generate() -> AsyncStream<String>  // stdout lines
}
```

- Runs `python3 <scriptDir>/generate.py` in user space (no root needed)
- Sets working directory to `<scriptDir>` (generate.py uses relative paths for rule JSON files)
- Sets `PATH` to include `/usr/local/bin:/usr/bin:/bin` (for `pgrep`, `pip`)
- Streams stdout line by line for progress display
- On success: triggers sing-box restart via SingBoxManager
- On failure: shows error alert, does not restart
- Prerequisite: `pyyaml` must be installed (`pip3 install pyyaml`); if missing, show error with install instructions

### 7. Launch at Login

- `SMAppService.mainApp.register()` / `.unregister()`
- Toggle in Settings view
- State read from `SMAppService.mainApp.status`

## Data Models

```swift
struct ProxyGroup: Identifiable, Codable {
    let id: String           // tag name
    let name: String
    let type: String         // "selector", "urltest"
    let now: String          // currently selected node
    let all: [String]        // all available node tags
}

struct ProxyNode: Identifiable, Codable {
    let id: String           // tag name
    let name: String
    let type: String         // "vmess", "trojan", etc.
    var delay: Int?          // latency in ms, nil = not tested
}

struct Connection: Identifiable, Codable {
    let id: String
    let host: String
    let rule: String
    let chains: [String]
    let downloadTotal: Int64
    let uploadTotal: Int64
    let start: Date
}

struct LogEntry: Identifiable {
    let id: UUID
    let level: String        // "debug", "info", "warning", "error"
    let message: String
    let timestamp: Date
}

struct Rule: Identifiable, Codable {
    let id: Int              // index
    let type: String
    let payload: String
    let proxy: String
}
```

## Sandboxing

BoxX **cannot** be sandboxed. It needs:
- XPC to a LaunchDaemon (root helper)
- `Process()` to run `python3` and access arbitrary file paths
- Local network access to `127.0.0.1:9091`

This means it cannot be distributed via the App Store. It is a local development tool for personal use.

## Error Handling

Errors surface to the user via:
- **Status bar icon**: gray = stopped, green = running, yellow = error state
- **Inline banners** in the main window for non-critical errors (API timeout, connection lost)
- **Alert dialogs** for critical errors (Helper install failed, sing-box binary not found, generate.py failed)
- **Graceful degradation**: if Clash API is unreachable, all views show "sing-box is not running" state instead of crashing

Specific error cases:
- Helper install denied by user → show instructions to manually authorize in System Settings
- sing-box binary missing → alert with "Install via: brew install sing-box"
- generate.py fails (pyyaml missing) → alert with "Run: pip3 install pyyaml"
- XPC permanently invalid → attempt reinstall helper, show alert if still fails

## What BoxX Does NOT Do

- Does not modify system proxy settings (sing-box TUN handles routing)
- Does not modify routing table
- Does not auto-switch nodes on recovery
- Does not regenerate config on recovery
- Helper does not make network requests or listen on ports
- Does not persist logs or connection history
- Does not include a built-in sing-box binary (uses system-installed one)
- Does not manage sing-box updates

## Dependencies

- None external. Pure Swift + SwiftUI + Foundation.
- Requires: `sing-box` installed (Homebrew), `python3` available, `generate.py` in script directory.

## Build & Run

```bash
cd singbox/BoxX
xcodebuild -scheme BoxX -configuration Debug build
# or open BoxX.xcodeproj in Xcode
```

Signing: Development signing with hardened runtime for local use. Both app and helper must be signed with the same team ID. Helper embedded at `BoxX.app/Contents/Library/LaunchDaemons/com.boxx.helper.plist`.

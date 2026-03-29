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

**Installation**:
- Uses `SMAppService.daemon(plistName:)` (macOS 13+)
- First launch: detect helper not installed → system authorization prompt (one-time password)
- Helper registered as LaunchDaemon, auto-restarts on crash

**Process management**:
- Start: `Process()` with `/usr/local/bin/sing-box run -c <configPath>`
- Stop: `SIGTERM` → wait 2s → `SIGKILL` fallback
- Helper holds process reference, cleans up on exit

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
- Show only top-level selectors (subscription groups + region groups), not individual nodes
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
- WebSocket pushes diffs, not full list
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
- Config file path (default: auto-detected from script directory)
- Subscriptions file path
- Helper status (installed/not installed) + reinstall button

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
          2. GET http://www.gstatic.com/generate_204 via proxy (timeout 5s)
             → fail → restart sing-box, done
          3. both pass → do nothing, done
```

**Constraints**:
- Does NOT call any Clash API to switch nodes
- Does NOT regenerate config
- Does NOT flush DNS
- Restart = stop + start same config → sing-box reads cache.db → same nodes as before
- Only one recovery in-flight at a time (guard with `Bool` flag)

### 6. Config Generator (`ConfigGenerator`)

**Implementation**: Calls existing `generate.py` via `Process`.

```swift
class ConfigGenerator {
    func generate() -> AsyncStream<String>  // stdout lines
}
```

- Runs `python3 <scriptDir>/generate.py` in user space (no root needed)
- Streams stdout line by line for progress display
- On success: triggers sing-box restart via SingBoxManager
- On failure: shows error, does not restart

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

Signing: Development signing for local use. Helper requires hardened runtime + embedded provisioning for SMAppService.

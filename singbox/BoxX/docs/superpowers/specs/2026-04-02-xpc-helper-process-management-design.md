# XPC Helper Process Management Design

**Date:** 2026-04-02
**Status:** Approved
**Scope:** BoxX macOS App - sing-box process management via XPC Helper

## Problem

BoxX currently manages sing-box via `sudo launchctl` commands, which:
- Requires sudoers configuration and `osascript` admin prompts
- StatusPoller cannot use `DispatchSource.makeProcessSource` to monitor a root process from a user-space app
- Polling Clash API for status wastes CPU and is unreliable

## Solution

Adopt a Surge-style architecture where the privileged Helper (already installed, `KeepAlive: true` via launchd) manages sing-box as a child process, and the main app communicates exclusively via XPC.

## Architecture

```
launchd (KeepAlive: true)
  +-- BoxXHelper (root, XPC Mach Service: com.boxx.helper)
        +-- sing-box (child process)
              - Crash/OOM -> Helper auto-restarts
              - Exit event -> DispatchSource notifies watchers

BoxX App (user)
  +-- SingBoxProcess -> all operations via XPC to Helper
  +-- StatusPoller -> Helper's watchProcessExit callback
  +-- No sudo, no launchctl, no sudoers
```

## XPC Protocol Changes

### Existing (retained as-is)
- `startSingBox(configPath:withReply:)` - Start sing-box with config
- `stopSingBox(withReply:)` - Stop sing-box
- `getStatus(withReply:)` - Get running status and PID
- `reloadSingBox(withReply:)` - Send SIGHUP for hot reload
- `flushDNS(withReply:)` - Flush DNS cache
- `setSystemProxy(port:withReply:)` - Set system HTTP proxy
- `clearSystemProxy(withReply:)` - Clear system proxy

### New
- `watchProcessExit(withReply:)` - Long-poll: Helper holds reply until sing-box exits, then returns `(wasRunning: Bool, exitCode: Int32)`. App re-calls to form a watch loop.

## Helper Changes (BoxXHelper/main.swift)

### Auto-restart on crash
- Save `lastConfigPath` when starting sing-box
- On `terminationHandler`: if `terminationStatus != 0` and not a deliberate stop (`isStopping` flag), wait 2 seconds then restart
- Deliberate stop via `stopSingBox()` sets `isStopping = true`, preventing auto-restart

### watchProcessExit implementation
- If sing-box is running: create `DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)`, store reply callback, fire when process exits
- If sing-box is not running: immediately reply `(false, 0)`
- Support multiple concurrent watchers (array of pending replies)

## SingBoxProcess Changes

### Removed
- `plistPath`, `plistLabel` constants
- `buildPlistContent()` - no more launchd plist generation
- `installPlist()` - no more sudoers/osascript
- `updatePlistConfigPath()`
- All `sudo launchctl bootstrap/bootout` calls
- All `sudo pkill` calls
- `findSingBoxPID()` / `findSingBoxPIDAsync()`
- `checkClashAPISync()` - no more HTTP polling

### Added
- `connectToHelper() -> HelperProtocol?` - XPC connection to Helper
- All operations delegate to Helper via XPC:
  - `start()` -> `helper.startSingBox(configPath:)`
  - `stop()` -> `helper.stopSingBox()`
  - `reload()` -> `helper.reloadSingBox()`
  - `flushDNS()` -> `helper.flushDNS()`
  - `refreshStatus()` -> `helper.getStatus()`

### start() flow
1. `configEngine.deployRuntime()`
2. `helper.startSingBox(configPath: runtimePath)` - wait for reply
3. Success -> `isRunning = true`
4. `helper.flushDNS()`

## StatusPoller Changes

Replace DispatchSource-based polling with XPC watch loop:

```
start(appState):
  1. helper.getStatus() -> initial state
  2. If running -> watchLoop()

watchLoop(appState):
  1. helper.watchProcessExit() -> blocks until exit
  2. On reply -> update isRunning, update icon
  3. helper.getStatus() -> check if Helper auto-restarted
  4. If still running -> watchLoop() again

nudge(appState):
  1. helper.getStatus() -> immediate refresh
  2. Update isRunning, icon
  3. Ensure watchLoop is running if needed
```

## Quit Flow

**Quit BoxX App:** Only quits the app. Does NOT stop sing-box. Helper continues managing sing-box, network stays up.

**Stop sing-box:** User clicks "Stop" in menu bar -> `helper.stopSingBox()`.

**Reopen App:** `getStatus()` detects sing-box running -> shows running state immediately.

## Migration (first upgrade)

On app launch, check for legacy `/Library/LaunchDaemons/com.boxx.singbox.plist`:
- If exists -> via Helper: `launchctl bootout system/com.boxx.singbox`, delete plist
- One-time migration, then fully XPC-based

## Files Changed

| File | Change |
|------|--------|
| `Shared/HelperProtocol.swift` | Add `watchProcessExit` method |
| `BoxXHelper/main.swift` | Auto-restart logic, watchProcessExit impl, store lastConfigPath |
| `BoxX/Services/SingBoxProcess.swift` | Remove sudo/launchctl, add XPC connection, delegate to Helper |
| `BoxX/BoxXApp.swift` | StatusPoller rewrite (XPC watch loop) |
| `BoxX/MenuBar/MenuBarController.swift` | Quit flow: don't stop sing-box |
| `BoxX/Views/OverviewView.swift` | Simplify doStart/doStop (no plist logic) |
| `BoxX/Views/SettingsView.swift` | Remove RunAtLoad toggle (launchd plist gone), keep Helper install UI |

## Not Changed

- Helper installation/uninstallation UI (already in Settings)
- ConfigEngine, route rules, DNS config
- WakeObserver (network recovery)
- Subscription management
- All UI views except OverviewView/SettingsView simplifications

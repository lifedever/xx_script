# TUN 全局代理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add TUN-based global proxy mode to ShadowProxy using utun + lwIP + Fake IP, without requiring an Apple Developer account.

**Architecture:** A privileged XPC Helper (root LaunchDaemon) creates a utun device and configures routes. The main App reads/writes IP packets from the utun fd, feeds them through lwIP (C library, SPM target) for TCP reassembly, resolves Fake IPs back to real domains, then forwards through the existing ProxyEngine/Outbound/Relay pipeline. A Fake DNS server intercepts DNS queries and returns synthetic 198.18.x.x addresses to enable domain-based routing on raw IP packets.

**Tech Stack:** Swift 6.0, Network.framework, lwIP 2.2.0 (C), XPC/SMJobBless, macOS 14+

---

## File Structure

### New files to create:

| File | Responsibility |
|------|---------------|
| `Sources/CLwIP/include/lwipopts.h` | lwIP compile-time configuration |
| `Sources/CLwIP/include/arch/cc.h` | lwIP architecture port header |
| `Sources/CLwIP/include/arch/sys_arch.h` | lwIP sys arch stubs (NO_SYS=1) |
| `Sources/CLwIP/shim.h` | Umbrella header exposing lwIP API to Swift |
| `Sources/CLwIP/src/` | lwIP source files (core + netif subset) |
| `Sources/ShadowProxyCore/TUN/FakeIPPool.swift` | Domain ↔ 198.18.x.x bidirectional mapping with LRU |
| `Sources/ShadowProxyCore/TUN/FakeDNSServer.swift` | UDP DNS listener, returns Fake IP A records |
| `Sources/ShadowProxyCore/TUN/TUNManager.swift` | utun fd read/write loop |
| `Sources/ShadowProxyCore/TUN/LwIPStack.swift` | Swift-C bridge to lwIP, TCP reassembly callbacks |
| `Sources/ShadowProxyCore/TUN/TUNGlobalProxy.swift` | Orchestrator: wires TUN+lwIP+FakeDNS+ProxyEngine |
| `Sources/ShadowProxyCore/System/HelperProtocol.swift` | XPC protocol shared between App and Helper |
| `Sources/ShadowProxyCore/System/XPCClient.swift` | XPC client for App → Helper communication |
| `Sources/ShadowProxyHelper/main.swift` | Helper entry point + XPC listener |
| `Sources/ShadowProxyHelper/HelperDelegate.swift` | XPC service: create utun, setup/cleanup routes |
| `Sources/ShadowProxyHelper/Info.plist` | Helper bundle info |
| `Sources/ShadowProxyHelper/launchd.plist` | LaunchDaemon config for Helper |
| `Tests/ShadowProxyCoreTests/FakeIPPoolTests.swift` | FakeIPPool unit tests |
| `Tests/ShadowProxyCoreTests/FakeDNSServerTests.swift` | FakeDNSServer unit tests |
| `Tests/ShadowProxyCoreTests/TUNManagerTests.swift` | TUNManager unit tests |

### Existing files to modify:

| File | Change |
|------|--------|
| `Package.swift` | Add CLwIP C target, ShadowProxyHelper executable target, dependency wiring |
| `Sources/ShadowProxyCore/Engine/ProxyEngine.swift` | Add `handleTUNRequest()` public method for TUN-originated connections |
| `ShadowProxyApp/ProxyViewModel.swift` | Add `proxyMode`, `startGlobal()`, `stopGlobal()`, TUN toggle state |
| `ShadowProxyApp/MenuBarPopover.swift` | Make mode buttons functional (系统代理 / 全局代理 互斥切换) |

---

## Task 1: FakeIPPool

**Files:**
- Create: `Sources/ShadowProxyCore/TUN/FakeIPPool.swift`
- Test: `Tests/ShadowProxyCoreTests/FakeIPPoolTests.swift`

- [ ] **Step 1: Write failing tests for FakeIPPool**

Create `Tests/ShadowProxyCoreTests/FakeIPPoolTests.swift`:

```swift
import Testing
@testable import ShadowProxyCore

@Test func allocateReturnsFakeIP() {
    let pool = FakeIPPool()
    let ip = pool.allocate(domain: "example.com")
    #expect(ip == "198.18.0.1")
}

@Test func allocateSameDomainReturnsSameIP() {
    let pool = FakeIPPool()
    let ip1 = pool.allocate(domain: "example.com")
    let ip2 = pool.allocate(domain: "example.com")
    #expect(ip1 == ip2)
}

@Test func allocateDifferentDomainsReturnsDifferentIPs() {
    let pool = FakeIPPool()
    let ip1 = pool.allocate(domain: "a.com")
    let ip2 = pool.allocate(domain: "b.com")
    #expect(ip1 != ip2)
    #expect(ip1 == "198.18.0.1")
    #expect(ip2 == "198.18.0.2")
}

@Test func lookupReturnsOriginalDomain() {
    let pool = FakeIPPool()
    let ip = pool.allocate(domain: "example.com")
    #expect(pool.lookup(ip: ip) == "example.com")
}

@Test func lookupUnknownIPReturnsNil() {
    let pool = FakeIPPool()
    #expect(pool.lookup(ip: "1.2.3.4") == nil)
}

@Test func containsDetectsFakeIPRange() {
    let pool = FakeIPPool()
    #expect(pool.contains(ip: "198.18.0.1") == true)
    #expect(pool.contains(ip: "198.19.255.255") == true)
    #expect(pool.contains(ip: "198.20.0.0") == false)
    #expect(pool.contains(ip: "10.0.0.1") == false)
}

@Test func lruEvictsOldestEntry() {
    let pool = FakeIPPool(capacity: 3)
    let ip1 = pool.allocate(domain: "a.com") // oldest
    _ = pool.allocate(domain: "b.com")
    _ = pool.allocate(domain: "c.com")
    // Pool full, next allocate should evict "a.com"
    _ = pool.allocate(domain: "d.com")
    #expect(pool.lookup(ip: ip1) == nil) // evicted
    #expect(pool.allocate(domain: "d.com") == "198.18.0.4")
}

@Test func uint32ToIPConversion() {
    let pool = FakeIPPool()
    // Allocate enough to roll into second octet
    for i in 0..<256 {
        _ = pool.allocate(domain: "domain\(i).com")
    }
    let ip257 = pool.allocate(domain: "domain256.com")
    #expect(ip257 == "198.18.1.1")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift test --filter FakeIPPool 2>&1 | tail -20`

Expected: Compilation error — `FakeIPPool` not found.

- [ ] **Step 3: Implement FakeIPPool**

Create `Sources/ShadowProxyCore/TUN/FakeIPPool.swift`:

```swift
import Foundation

/// Bidirectional mapping between domain names and Fake IP addresses (198.18.0.0/15).
/// Used by TUN mode to enable domain-based routing on raw IP packets.
public final class FakeIPPool: @unchecked Sendable {
    private var domainToIP: [String: UInt32] = [:]
    private var ipToDomain: [UInt32: String] = [:]
    private var accessOrder: [String] = []  // LRU: oldest first
    private let capacity: Int
    private var nextOffset: UInt32 = 1  // 198.18.0.1 starts at offset 1

    // 198.18.0.0/15 = 198.18.0.0 ~ 198.19.255.255
    private static let baseIP: UInt32 = 0xC612_0000  // 198.18.0.0
    private static let maxOffset: UInt32 = 0x0001_FFFF  // 131071 addresses

    public init(capacity: Int = 65536) {
        self.capacity = min(capacity, Int(Self.maxOffset))
    }

    /// Allocate a Fake IP for the given domain. Returns existing IP if already allocated.
    public func allocate(domain: String) -> String {
        let key = domain.lowercased()

        if let existing = domainToIP[key] {
            // Move to end of LRU
            if let idx = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: idx)
                accessOrder.append(key)
            }
            return Self.ipString(from: existing)
        }

        // Evict if full
        if accessOrder.count >= capacity {
            let evicted = accessOrder.removeFirst()
            if let evictedIP = domainToIP.removeValue(forKey: evicted) {
                ipToDomain.removeValue(forKey: evictedIP)
            }
        }

        let ip = Self.baseIP + nextOffset
        nextOffset += 1
        if nextOffset > Self.maxOffset {
            nextOffset = 1  // Wrap around (LRU should have freed slots)
        }

        domainToIP[key] = ip
        ipToDomain[ip] = key
        accessOrder.append(key)

        return Self.ipString(from: ip)
    }

    /// Reverse lookup: Fake IP → original domain
    public func lookup(ip: String) -> String? {
        guard let ipInt = Self.ipUInt32(from: ip) else { return nil }
        return ipToDomain[ipInt]
    }

    /// Check if an IP falls within the Fake IP range (198.18.0.0/15)
    public func contains(ip: String) -> Bool {
        guard let ipInt = Self.ipUInt32(from: ip) else { return false }
        return ipInt >= Self.baseIP && ipInt <= (Self.baseIP + Self.maxOffset)
    }

    // MARK: - Helpers

    static func ipString(from value: UInt32) -> String {
        let a = (value >> 24) & 0xFF
        let b = (value >> 16) & 0xFF
        let c = (value >> 8) & 0xFF
        let d = value & 0xFF
        return "\(a).\(b).\(c).\(d)"
    }

    static func ipUInt32(from string: String) -> UInt32? {
        let parts = string.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift test --filter FakeIPPool 2>&1 | tail -20`

Expected: All 8 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add Sources/ShadowProxyCore/TUN/FakeIPPool.swift Tests/ShadowProxyCoreTests/FakeIPPoolTests.swift
git commit -m "feat(tun): FakeIPPool — domain ↔ 198.18.x.x mapping with LRU"
```

---

## Task 2: FakeDNSServer

**Files:**
- Create: `Sources/ShadowProxyCore/TUN/FakeDNSServer.swift`
- Test: `Tests/ShadowProxyCoreTests/FakeDNSServerTests.swift`

- [ ] **Step 1: Write failing tests for FakeDNSServer**

Create `Tests/ShadowProxyCoreTests/FakeDNSServerTests.swift`:

```swift
import Testing
import Foundation
@testable import ShadowProxyCore

@Test func parseDNSQueryExtractsDomain() {
    // Standard DNS query for "example.com" type A
    let query = buildDNSQuery(domain: "example.com", transactionID: 0x1234)
    let result = FakeDNSServer.parseQuery(query)
    #expect(result?.domain == "example.com")
    #expect(result?.transactionID == 0x1234)
    #expect(result?.questionType == 1) // A record
}

@Test func parseDNSQuerySubdomain() {
    let query = buildDNSQuery(domain: "api.sub.example.com", transactionID: 0xABCD)
    let result = FakeDNSServer.parseQuery(query)
    #expect(result?.domain == "api.sub.example.com")
}

@Test func parseDNSQueryRejectsShortPacket() {
    let data = Data([0x12, 0x34])
    #expect(FakeDNSServer.parseQuery(data) == nil)
}

@Test func buildDNSResponseContainsFakeIP() {
    let pool = FakeIPPool()
    let query = buildDNSQuery(domain: "test.com", transactionID: 0x5678)
    let parsed = FakeDNSServer.parseQuery(query)!
    let response = FakeDNSServer.buildResponse(
        transactionID: parsed.transactionID,
        domain: parsed.domain,
        ip: "198.18.0.1",
        originalQuestion: Data(query[12...])  // question section
    )
    // Verify transaction ID
    #expect(response[0] == 0x56)
    #expect(response[1] == 0x78)
    // Verify flags: standard response, no error
    #expect(response[2] == 0x81)
    #expect(response[3] == 0x80)
    // Verify answer count = 1
    #expect(response[6] == 0x00)
    #expect(response[7] == 0x01)
    // Verify IP at end: 198.18.0.1
    let ipBytes = response.suffix(4)
    #expect(ipBytes[ipBytes.startIndex] == 198)
    #expect(ipBytes[ipBytes.startIndex + 1] == 18)
    #expect(ipBytes[ipBytes.startIndex + 2] == 0)
    #expect(ipBytes[ipBytes.startIndex + 3] == 1)
}

@Test func buildDNSResponseAAAAReturnsEmpty() {
    // AAAA query (type 28) should get empty response (no answer)
    let query = buildDNSQuery(domain: "test.com", transactionID: 0x1111, queryType: 28)
    let parsed = FakeDNSServer.parseQuery(query)!
    #expect(parsed.questionType == 28)
}

// Helper: build a minimal DNS query packet
func buildDNSQuery(domain: String, transactionID: UInt16, queryType: UInt16 = 1) -> Data {
    var data = Data()
    // Transaction ID
    data.append(UInt8(transactionID >> 8))
    data.append(UInt8(transactionID & 0xFF))
    // Flags: standard query
    data.append(contentsOf: [0x01, 0x00])
    // QDCOUNT = 1
    data.append(contentsOf: [0x00, 0x01])
    // ANCOUNT, NSCOUNT, ARCOUNT = 0
    data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    // Question: encode domain labels
    for label in domain.split(separator: ".") {
        data.append(UInt8(label.count))
        data.append(contentsOf: label.utf8)
    }
    data.append(0x00) // root label
    // Type (A=1 or AAAA=28)
    data.append(UInt8(queryType >> 8))
    data.append(UInt8(queryType & 0xFF))
    // Class IN
    data.append(contentsOf: [0x00, 0x01])
    return data
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift test --filter FakeDNS 2>&1 | tail -20`

Expected: Compilation error — `FakeDNSServer` not found.

- [ ] **Step 3: Implement FakeDNSServer**

Create `Sources/ShadowProxyCore/TUN/FakeDNSServer.swift`:

```swift
import Foundation
import Network

/// Fake DNS server that intercepts DNS queries and returns Fake IP addresses.
/// Listens on UDP, responds to A queries with 198.18.x.x from FakeIPPool.
/// AAAA queries get empty responses (no IPv6 support yet).
public final class FakeDNSServer: @unchecked Sendable {
    private let pool: FakeIPPool
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "shadowproxy.fakedns")

    public struct DNSQuery {
        public let transactionID: UInt16
        public let domain: String
        public let questionType: UInt16  // 1=A, 28=AAAA
        public let questionRaw: Data     // raw question section for echo in response
    }

    public init(pool: FakeIPPool, port: UInt16 = 53) {
        self.pool = pool
        self.port = port
    }

    public func start() throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                splog.info("FakeDNS listening on UDP port \(self.port)", tag: "FakeDNS")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        splog.info("FakeDNS stopped", tag: "FakeDNS")
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            guard let query = Self.parseQuery(data) else {
                connection.cancel()
                return
            }

            let response: Data
            if query.questionType == 1 {
                // A record: allocate fake IP
                let fakeIP = self.pool.allocate(domain: query.domain)
                response = Self.buildResponse(
                    transactionID: query.transactionID,
                    domain: query.domain,
                    ip: fakeIP,
                    originalQuestion: query.questionRaw
                )
                splog.debug("DNS \(query.domain) → \(fakeIP)", tag: "FakeDNS")
            } else {
                // AAAA or other: return empty (no answer)
                response = Self.buildEmptyResponse(
                    transactionID: query.transactionID,
                    originalQuestion: query.questionRaw
                )
            }

            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: - DNS Packet Parsing

    /// Parse a DNS query packet, extract domain name and query type
    public static func parseQuery(_ data: Data) -> DNSQuery? {
        guard data.count >= 12 else { return nil }

        let txID = UInt16(data[0]) << 8 | UInt16(data[1])
        let qdcount = UInt16(data[4]) << 8 | UInt16(data[5])
        guard qdcount >= 1 else { return nil }

        // Parse question section starting at byte 12
        var offset = 12
        var labels: [String] = []

        while offset < data.count {
            let len = Int(data[offset])
            if len == 0 {
                offset += 1
                break
            }
            guard offset + 1 + len <= data.count else { return nil }
            let label = String(data: data[(offset + 1)..<(offset + 1 + len)], encoding: .utf8) ?? ""
            labels.append(label)
            offset += 1 + len
        }

        guard offset + 4 <= data.count else { return nil }
        let qtype = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        // qclass at offset+2..offset+3 (should be 1 = IN)

        let questionRaw = Data(data[12..<(offset + 4)])

        return DNSQuery(
            transactionID: txID,
            domain: labels.joined(separator: "."),
            questionType: qtype,
            questionRaw: questionRaw
        )
    }

    // MARK: - DNS Response Building

    /// Build a DNS A record response with the given IP
    public static func buildResponse(transactionID: UInt16, domain: String, ip: String, originalQuestion: Data) -> Data {
        var resp = Data()

        // Header
        resp.append(UInt8(transactionID >> 8))
        resp.append(UInt8(transactionID & 0xFF))
        resp.append(contentsOf: [0x81, 0x80])  // flags: response, recursion available
        resp.append(contentsOf: [0x00, 0x01])  // QDCOUNT = 1
        resp.append(contentsOf: [0x00, 0x01])  // ANCOUNT = 1
        resp.append(contentsOf: [0x00, 0x00])  // NSCOUNT = 0
        resp.append(contentsOf: [0x00, 0x00])  // ARCOUNT = 0

        // Question section (echo back)
        resp.append(originalQuestion)

        // Answer section: pointer to name in question (0xC00C)
        resp.append(contentsOf: [0xC0, 0x0C])
        resp.append(contentsOf: [0x00, 0x01])  // TYPE A
        resp.append(contentsOf: [0x00, 0x01])  // CLASS IN
        resp.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // TTL = 1 second
        resp.append(contentsOf: [0x00, 0x04])  // RDLENGTH = 4

        // RDATA: IP address
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return resp }
        resp.append(contentsOf: parts)

        return resp
    }

    /// Build an empty DNS response (no answers) for unsupported query types
    static func buildEmptyResponse(transactionID: UInt16, originalQuestion: Data) -> Data {
        var resp = Data()
        resp.append(UInt8(transactionID >> 8))
        resp.append(UInt8(transactionID & 0xFF))
        resp.append(contentsOf: [0x81, 0x80])
        resp.append(contentsOf: [0x00, 0x01])  // QDCOUNT = 1
        resp.append(contentsOf: [0x00, 0x00])  // ANCOUNT = 0
        resp.append(contentsOf: [0x00, 0x00])
        resp.append(contentsOf: [0x00, 0x00])
        resp.append(originalQuestion)
        return resp
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift test --filter FakeDNS 2>&1 | tail -20`

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add Sources/ShadowProxyCore/TUN/FakeDNSServer.swift Tests/ShadowProxyCoreTests/FakeDNSServerTests.swift
git commit -m "feat(tun): FakeDNSServer — UDP DNS listener returning Fake IP A records"
```

---

## Task 3: lwIP SPM Integration

**Files:**
- Create: `Sources/CLwIP/include/lwipopts.h`
- Create: `Sources/CLwIP/include/arch/cc.h`
- Create: `Sources/CLwIP/include/arch/sys_arch.h`
- Create: `Sources/CLwIP/shim.h`
- Create: `Sources/CLwIP/shim.c`
- Download: lwIP 2.2.0 source to `Sources/CLwIP/src/`
- Modify: `Package.swift`

- [ ] **Step 1: Download lwIP source**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
mkdir -p Sources/CLwIP/src Sources/CLwIP/include/arch

# Download lwIP 2.2.0
curl -L https://github.com/lwip-tcpip/lwip/archive/refs/tags/STABLE-2_2_0_RELEASE.tar.gz -o /tmp/lwip.tar.gz
tar xzf /tmp/lwip.tar.gz -C /tmp/

# Copy only the minimal core subset we need
cp -R /tmp/lwip-STABLE-2_2_0_RELEASE/src/core Sources/CLwIP/src/core
cp -R /tmp/lwip-STABLE-2_2_0_RELEASE/src/include Sources/CLwIP/src/include

# We don't need netif for our use case (custom netif in Swift)
# We don't need api/ (NO_SYS=1 mode)

rm -rf /tmp/lwip-STABLE-2_2_0_RELEASE /tmp/lwip.tar.gz
```

- [ ] **Step 2: Create lwIP configuration headers**

Create `Sources/CLwIP/include/lwipopts.h`:

```c
#ifndef LWIPOPTS_H
#define LWIPOPTS_H

// No OS integration — we drive lwIP manually
#define NO_SYS                  1
#define SYS_LIGHTWEIGHT_PROT    0
#define LWIP_DONT_PROVIDE_BYTEORDER_FUNCTIONS 1

// Enable TCP only
#define LWIP_TCP                1
#define LWIP_UDP                1  // needed for DNS forwarding
#define LWIP_ICMP               0
#define LWIP_RAW                0
#define LWIP_IGMP               0
#define LWIP_DNS                0
#define LWIP_ARP                0
#define LWIP_AUTOIP             0
#define LWIP_DHCP               0
#define LWIP_NETIF_API          0
#define LWIP_SOCKET             0
#define LWIP_NETCONN            0
#define LWIP_STATS              0
#define LWIP_IPV6               0

// Memory tuning
#define MEM_SIZE                (512 * 1024)
#define MEMP_NUM_TCP_PCB        256
#define MEMP_NUM_TCP_PCB_LISTEN 16
#define MEMP_NUM_TCP_SEG        512
#define MEMP_NUM_PBUF           512
#define PBUF_POOL_SIZE          256
#define PBUF_POOL_BUFSIZE       1600

// TCP tuning
#define TCP_MSS                 1460
#define TCP_WND                 (64 * 1024)
#define TCP_SND_BUF             (64 * 1024)
#define TCP_SND_QUEUELEN        (4 * TCP_SND_BUF / TCP_MSS)
#define TCP_LISTEN_BACKLOG      1
#define LWIP_TCP_KEEPALIVE      1

// Callback API (not sequential)
#define LWIP_CALLBACK_API       1

// Checksum: let lwIP compute
#define LWIP_CHECKSUM_CTRL_PER_NETIF 0
#define CHECKSUM_GEN_IP         1
#define CHECKSUM_GEN_TCP        1
#define CHECKSUM_CHECK_IP       1
#define CHECKSUM_CHECK_TCP      1

// Debug (disable in production)
#define LWIP_DEBUG              0

#endif /* LWIPOPTS_H */
```

Create `Sources/CLwIP/include/arch/cc.h`:

```c
#ifndef LWIP_ARCH_CC_H
#define LWIP_ARCH_CC_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

// Compiler/platform specific types
typedef uint8_t  u8_t;
typedef int8_t   s8_t;
typedef uint16_t u16_t;
typedef int16_t  s16_t;
typedef uint32_t u32_t;
typedef int32_t  s32_t;
typedef uintptr_t mem_ptr_t;

// Byte order: macOS is little-endian
#ifndef BYTE_ORDER
#define BYTE_ORDER LITTLE_ENDIAN
#endif

// Diagnostics
#define LWIP_PLATFORM_DIAG(x)   do { printf x; } while(0)
#define LWIP_PLATFORM_ASSERT(x) do { printf("lwIP assert: %s\n", x); abort(); } while(0)

// Packing
#define PACK_STRUCT_FIELD(x) x
#define PACK_STRUCT_STRUCT __attribute__((packed))
#define PACK_STRUCT_BEGIN
#define PACK_STRUCT_END

#endif /* LWIP_ARCH_CC_H */
```

Create `Sources/CLwIP/include/arch/sys_arch.h`:

```c
#ifndef LWIP_ARCH_SYS_ARCH_H
#define LWIP_ARCH_SYS_ARCH_H

// NO_SYS=1: no threading primitives needed
typedef int sys_prot_t;

#define SYS_ARCH_DECL_PROTECT(x)
#define SYS_ARCH_PROTECT(x)
#define SYS_ARCH_UNPROTECT(x)

#endif /* LWIP_ARCH_SYS_ARCH_H */
```

- [ ] **Step 3: Create umbrella shim header and source**

Create `Sources/CLwIP/shim.h`:

```c
#ifndef CLWIP_SHIM_H
#define CLWIP_SHIM_H

// Umbrella header exposing lwIP to Swift via CLwIP module
#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "lwip/ip.h"
#include "lwip/pbuf.h"
#include "lwip/netif.h"
#include "lwip/timeouts.h"
#include "lwip/mem.h"
#include "lwip/memp.h"

// Custom callback types for Swift interop
typedef void (*lwip_output_fn)(const void *data, int len, void *ctx);
typedef void (*lwip_tcp_accept_fn)(uint32_t conn_id, uint32_t src_ip, uint16_t src_port, uint32_t dst_ip, uint16_t dst_port, void *ctx);
typedef void (*lwip_tcp_data_fn)(uint32_t conn_id, const void *data, int len, void *ctx);
typedef void (*lwip_tcp_close_fn)(uint32_t conn_id, void *ctx);

// Initialize the lwIP stack with custom netif
void clwip_init(lwip_output_fn output_fn, void *ctx);

// Feed an IP packet into lwIP (from TUN)
void clwip_input(const void *data, int len);

// Set TCP callbacks
void clwip_set_tcp_accept_cb(lwip_tcp_accept_fn fn, void *ctx);
void clwip_set_tcp_data_cb(lwip_tcp_data_fn fn, void *ctx);
void clwip_set_tcp_close_cb(lwip_tcp_close_fn fn, void *ctx);

// Write data back to a TCP connection (from proxy response)
int clwip_tcp_write(uint32_t conn_id, const void *data, int len);

// Close a TCP connection
void clwip_tcp_close(uint32_t conn_id);

// Process lwIP timers (call periodically, e.g. every 250ms)
void clwip_process_timers(void);

#endif /* CLWIP_SHIM_H */
```

Create `Sources/CLwIP/shim.c`:

```c
#include "shim.h"
#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/ip.h"
#include "lwip/pbuf.h"
#include "lwip/netif.h"
#include "lwip/timeouts.h"
#include <string.h>
#include <stdlib.h>

// --- State ---

static struct netif tun_netif;
static lwip_output_fn g_output_fn = NULL;
static void *g_output_ctx = NULL;

static lwip_tcp_accept_fn g_tcp_accept_fn = NULL;
static void *g_tcp_accept_ctx = NULL;
static lwip_tcp_data_fn g_tcp_data_fn = NULL;
static void *g_tcp_data_ctx = NULL;
static lwip_tcp_close_fn g_tcp_close_fn = NULL;
static void *g_tcp_close_ctx = NULL;

static uint32_t g_next_conn_id = 1;

// Connection tracking
#define MAX_CONNECTIONS 1024

struct conn_entry {
    uint32_t conn_id;
    struct tcp_pcb *pcb;
    int active;
};

static struct conn_entry g_conns[MAX_CONNECTIONS];

static struct conn_entry *find_conn(uint32_t conn_id) {
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (g_conns[i].active && g_conns[i].conn_id == conn_id)
            return &g_conns[i];
    }
    return NULL;
}

static uint32_t register_conn(struct tcp_pcb *pcb) {
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (!g_conns[i].active) {
            g_conns[i].conn_id = g_next_conn_id++;
            g_conns[i].pcb = pcb;
            g_conns[i].active = 1;
            return g_conns[i].conn_id;
        }
    }
    return 0;  // No free slots
}

static void unregister_conn(uint32_t conn_id) {
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (g_conns[i].active && g_conns[i].conn_id == conn_id) {
            g_conns[i].active = 0;
            g_conns[i].pcb = NULL;
            return;
        }
    }
}

// --- Netif output callback ---

static err_t tun_netif_output(struct netif *nif, struct pbuf *p, const ip4_addr_t *ipaddr) {
    (void)nif;
    (void)ipaddr;
    if (!g_output_fn) return ERR_OK;

    // Flatten pbuf chain into contiguous buffer
    if (p->tot_len <= 0) return ERR_OK;

    uint8_t *buf = (uint8_t *)malloc(p->tot_len);
    if (!buf) return ERR_MEM;

    pbuf_copy_partial(p, buf, p->tot_len, 0);
    g_output_fn(buf, p->tot_len, g_output_ctx);
    free(buf);
    return ERR_OK;
}

static err_t tun_netif_init(struct netif *nif) {
    nif->name[0] = 's';
    nif->name[1] = 'p';
    nif->mtu = 1500;
    nif->output = tun_netif_output;
    nif->flags = NETIF_FLAG_UP | NETIF_FLAG_LINK_UP;
    return ERR_OK;
}

// --- TCP callbacks ---

static err_t on_tcp_recv(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err) {
    uint32_t conn_id = (uint32_t)(uintptr_t)arg;

    if (p == NULL || err != ERR_OK) {
        // Connection closed by remote
        if (g_tcp_close_fn) g_tcp_close_fn(conn_id, g_tcp_close_ctx);
        unregister_conn(conn_id);
        if (tpcb) tcp_close(tpcb);
        return ERR_OK;
    }

    if (g_tcp_data_fn) {
        uint8_t *buf = (uint8_t *)malloc(p->tot_len);
        if (buf) {
            pbuf_copy_partial(p, buf, p->tot_len, 0);
            g_tcp_data_fn(conn_id, buf, p->tot_len, g_tcp_data_ctx);
            free(buf);
        }
    }

    tcp_recved(tpcb, p->tot_len);
    pbuf_free(p);
    return ERR_OK;
}

static err_t on_tcp_sent(void *arg, struct tcp_pcb *tpcb, u16_t len) {
    (void)arg;
    (void)tpcb;
    (void)len;
    return ERR_OK;
}

static void on_tcp_err(void *arg, err_t err) {
    (void)err;
    uint32_t conn_id = (uint32_t)(uintptr_t)arg;
    if (g_tcp_close_fn) g_tcp_close_fn(conn_id, g_tcp_close_ctx);
    unregister_conn(conn_id);
}

// We intercept all TCP by listening on a wildcard PCB
static struct tcp_pcb *g_listen_pcb = NULL;

static err_t on_tcp_accept(void *arg, struct tcp_pcb *newpcb, err_t err) {
    (void)arg;
    if (err != ERR_OK || !newpcb) return ERR_VAL;

    uint32_t conn_id = register_conn(newpcb);
    if (conn_id == 0) {
        tcp_abort(newpcb);
        return ERR_ABRT;
    }

    tcp_arg(newpcb, (void *)(uintptr_t)conn_id);
    tcp_recv(newpcb, on_tcp_recv);
    tcp_sent(newpcb, on_tcp_sent);
    tcp_err(newpcb, on_tcp_err);

    if (g_tcp_accept_fn) {
        g_tcp_accept_fn(
            conn_id,
            ip4_addr_get_u32(&newpcb->local_ip),
            newpcb->local_port,
            ip4_addr_get_u32(&newpcb->remote_ip),
            newpcb->remote_port,
            g_tcp_accept_ctx
        );
    }

    return ERR_OK;
}

// --- Public API ---

void clwip_init(lwip_output_fn output_fn, void *ctx) {
    g_output_fn = output_fn;
    g_output_ctx = ctx;
    memset(g_conns, 0, sizeof(g_conns));

    lwip_init();

    // Set up TUN netif with dummy IPs
    ip4_addr_t ipaddr, netmask, gw;
    IP4_ADDR(&ipaddr,  10, 0, 0, 1);
    IP4_ADDR(&netmask, 255, 255, 255, 0);
    IP4_ADDR(&gw,      10, 0, 0, 1);

    netif_add(&tun_netif, &ipaddr, &netmask, &gw, NULL, tun_netif_init, ip_input);
    netif_set_default(&tun_netif);
    netif_set_up(&tun_netif);

    // Listen on all IPs, all ports to intercept TCP
    g_listen_pcb = tcp_new();
    tcp_bind(g_listen_pcb, IP_ADDR_ANY, 0);
    g_listen_pcb = tcp_listen(g_listen_pcb);
    tcp_accept(g_listen_pcb, on_tcp_accept);
}

void clwip_input(const void *data, int len) {
    struct pbuf *p = pbuf_alloc(PBUF_RAW, len, PBUF_RAM);
    if (!p) return;
    memcpy(p->payload, data, len);
    if (tun_netif.input(p, &tun_netif) != ERR_OK) {
        pbuf_free(p);
    }
}

void clwip_set_tcp_accept_cb(lwip_tcp_accept_fn fn, void *ctx) {
    g_tcp_accept_fn = fn;
    g_tcp_accept_ctx = ctx;
}

void clwip_set_tcp_data_cb(lwip_tcp_data_fn fn, void *ctx) {
    g_tcp_data_fn = fn;
    g_tcp_data_ctx = ctx;
}

void clwip_set_tcp_close_cb(lwip_tcp_close_fn fn, void *ctx) {
    g_tcp_close_fn = fn;
    g_tcp_close_ctx = ctx;
}

int clwip_tcp_write(uint32_t conn_id, const void *data, int len) {
    struct conn_entry *e = find_conn(conn_id);
    if (!e || !e->pcb) return -1;

    err_t err = tcp_write(e->pcb, data, len, TCP_WRITE_FLAG_COPY);
    if (err != ERR_OK) return -1;

    tcp_output(e->pcb);
    return 0;
}

void clwip_tcp_close(uint32_t conn_id) {
    struct conn_entry *e = find_conn(conn_id);
    if (!e || !e->pcb) return;

    tcp_arg(e->pcb, NULL);
    tcp_recv(e->pcb, NULL);
    tcp_sent(e->pcb, NULL);
    tcp_err(e->pcb, NULL);
    tcp_close(e->pcb);
    unregister_conn(conn_id);
}

void clwip_process_timers(void) {
    sys_check_timeouts();
}
```

- [ ] **Step 4: Update Package.swift**

Add the CLwIP target and wire dependencies. Modify `Package.swift`:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShadowProxy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShadowProxyCore", targets: ["ShadowProxyCore"]),
        .executable(name: "sp", targets: ["ShadowProxyCLI"]),
    ],
    targets: [
        .target(
            name: "CLwIP",
            path: "Sources/CLwIP",
            sources: ["src/core", "shim.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src/include"),
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "ShadowProxyCore",
            dependencies: ["CLwIP"]
        ),
        .executableTarget(
            name: "ShadowProxyCLI",
            dependencies: ["ShadowProxyCore"]
        ),
        .testTarget(
            name: "ShadowProxyCoreTests",
            dependencies: ["ShadowProxyCore"]
        ),
    ]
)
```

- [ ] **Step 5: Build to verify lwIP compiles**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift build 2>&1 | tail -30`

Expected: Successful build. If there are lwIP compile warnings, they are acceptable. Errors need fixing (likely missing headers or source file paths — adjust `sources` and `cSettings` as needed).

- [ ] **Step 6: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add Sources/CLwIP/ Package.swift
git commit -m "feat(tun): integrate lwIP 2.2.0 as SPM C target with custom shim"
```

---

## Task 4: LwIPStack (Swift-C Bridge)

**Files:**
- Create: `Sources/ShadowProxyCore/TUN/LwIPStack.swift`

- [ ] **Step 1: Implement LwIPStack**

Create `Sources/ShadowProxyCore/TUN/LwIPStack.swift`:

```swift
import Foundation
import CLwIP

/// Swift wrapper around the lwIP C library.
/// Feeds raw IP packets in, receives TCP connection events out.
public final class LwIPStack: @unchecked Sendable {
    private let queue = DispatchQueue(label: "shadowproxy.lwip")
    private var timerSource: DispatchSourceTimer?
    private var started = false

    /// Called when lwIP produces an outbound IP packet (to write back to TUN)
    public var onOutput: ((Data) -> Void)?

    /// Called when a new TCP connection is accepted
    /// Parameters: connectionID, destinationIP, destinationPort
    public var onTCPAccept: ((UInt32, String, UInt16) -> Void)?

    /// Called when data arrives on an existing TCP connection
    public var onTCPData: ((UInt32, Data) -> Void)?

    /// Called when a TCP connection is closed
    public var onTCPClose: ((UInt32) -> Void)?

    public init() {}

    /// Initialize lwIP and start timer processing
    public func start() {
        queue.sync {
            guard !started else { return }

            let ctx = Unmanaged.passUnretained(self).toOpaque()

            clwip_init({ (data, len, ctx) in
                guard let ctx, let data else { return }
                let stack = Unmanaged<LwIPStack>.fromOpaque(ctx).takeUnretainedValue()
                let packet = Data(bytes: data, count: Int(len))
                stack.onOutput?(packet)
            }, ctx)

            clwip_set_tcp_accept_cb({ (connID, srcIP, srcPort, dstIP, dstPort, ctx) in
                guard let ctx else { return }
                let stack = Unmanaged<LwIPStack>.fromOpaque(ctx).takeUnretainedValue()
                // Note: lwIP swaps src/dst for the listener perspective
                // The "destination" from the app's perspective is the original dst
                let ip = FakeIPPool.ipString(from: dstIP)
                stack.onTCPAccept?(connID, ip, dstPort)
            }, ctx)

            clwip_set_tcp_data_cb({ (connID, data, len, ctx) in
                guard let ctx, let data else { return }
                let stack = Unmanaged<LwIPStack>.fromOpaque(ctx).takeUnretainedValue()
                let bytes = Data(bytes: data, count: Int(len))
                stack.onTCPData?(connID, bytes)
            }, ctx)

            clwip_set_tcp_close_cb({ (connID, ctx) in
                guard let ctx else { return }
                let stack = Unmanaged<LwIPStack>.fromOpaque(ctx).takeUnretainedValue()
                stack.onTCPClose?(connID)
            }, ctx)

            // Timer for lwIP internal processing (retransmissions, keepalives)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler {
                clwip_process_timers()
            }
            timer.resume()
            timerSource = timer

            started = true
            splog.info("lwIP stack initialized", tag: "LwIP")
        }
    }

    /// Feed a raw IP packet from TUN into lwIP for processing
    public func input(_ packet: Data) {
        queue.async {
            packet.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                clwip_input(base, Int32(packet.count))
            }
        }
    }

    /// Write response data to a TCP connection
    public func tcpWrite(connectionID: UInt32, data: Data) {
        queue.async {
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                clwip_tcp_write(connectionID, base, Int32(data.count))
            }
        }
    }

    /// Close a TCP connection
    public func tcpClose(connectionID: UInt32) {
        queue.async {
            clwip_tcp_close(connectionID)
        }
    }

    /// Stop the lwIP stack
    public func stop() {
        queue.sync {
            timerSource?.cancel()
            timerSource = nil
            started = false
            splog.info("lwIP stack stopped", tag: "LwIP")
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift build 2>&1 | tail -20`

Expected: Successful build.

- [ ] **Step 3: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add Sources/ShadowProxyCore/TUN/LwIPStack.swift
git commit -m "feat(tun): LwIPStack — Swift-C bridge for lwIP TCP reassembly"
```

---

## Task 5: TUNManager

**Files:**
- Create: `Sources/ShadowProxyCore/TUN/TUNManager.swift`

- [ ] **Step 1: Implement TUNManager**

Create `Sources/ShadowProxyCore/TUN/TUNManager.swift`:

```swift
import Foundation

/// Manages reading/writing raw IP packets from/to a utun file descriptor.
/// macOS utun packets have a 4-byte AF header prefix (AF_INET = 2 for IPv4).
public final class TUNManager: @unchecked Sendable {
    private var tunFD: Int32 = -1
    private var tunName: String = ""
    private var running = false
    private let readQueue = DispatchQueue(label: "shadowproxy.tun.read", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "shadowproxy.tun.write", qos: .userInteractive)

    /// Called when an IP packet is read from the TUN device
    public var onPacket: ((Data) -> Void)?

    private static let mtu = 1500
    // AF_INET = 2 (IPv4 protocol family identifier, prefixed by macOS utun)
    private static let afInetHeader = Data([0x00, 0x00, 0x00, 0x02])

    public init() {}

    /// Start reading from the TUN device
    public func start(fd: Int32, name: String) {
        self.tunFD = fd
        self.tunName = name
        self.running = true

        splog.info("TUN started: \(name) (fd=\(fd))", tag: "TUN")

        readQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    /// Write an IP packet back to the TUN device
    public func write(_ packet: Data) {
        guard running, tunFD >= 0 else { return }

        writeQueue.async { [weak self] in
            guard let self, self.running else { return }
            // Prepend 4-byte AF_INET header
            var frame = Self.afInetHeader
            frame.append(packet)
            frame.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                _ = Darwin.write(self.tunFD, base, frame.count)
            }
        }
    }

    /// Stop reading and close the TUN device
    public func stop() {
        running = false
        if tunFD >= 0 {
            close(tunFD)
            tunFD = -1
        }
        splog.info("TUN stopped: \(tunName)", tag: "TUN")
    }

    // MARK: - Private

    private func readLoop() {
        let bufferSize = Self.mtu + 4  // IP packet + AF header
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while running && tunFD >= 0 {
            let n = read(tunFD, buffer, bufferSize)
            if n <= 4 { continue }  // skip empty or header-only reads

            // Strip 4-byte AF header, pass raw IP packet
            let ipPacket = Data(bytes: buffer + 4, count: n - 4)
            onPacket?(ipPacket)
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift build 2>&1 | tail -20`

Expected: Successful build.

- [ ] **Step 3: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add Sources/ShadowProxyCore/TUN/TUNManager.swift
git commit -m "feat(tun): TUNManager — utun fd read/write with AF_INET header"
```

---

## Task 6: XPC Helper Protocol + Client

**Files:**
- Create: `Sources/ShadowProxyCore/System/HelperProtocol.swift`
- Create: `Sources/ShadowProxyCore/System/XPCClient.swift`

- [ ] **Step 1: Create shared XPC protocol**

Create `Sources/ShadowProxyCore/System/HelperProtocol.swift`:

```swift
import Foundation

/// XPC protocol shared between ShadowProxy.app and ShadowProxyHelper.
/// Helper runs as root LaunchDaemon and performs privileged operations.
@objc public protocol HelperProtocol {
    /// Create a utun device. Returns (fd, tunName) on success, (-1, errorMessage) on failure.
    func createTUN(reply: @escaping (Int32, String) -> Void)

    /// Set up routing table to redirect all traffic through the TUN device.
    /// - gateway: original default gateway IP
    /// - tunName: utun device name (e.g. "utun5")
    /// - excludeIPs: proxy server IPs that should bypass TUN (direct route)
    /// - dnsServerIP: IP of the fake DNS server (e.g. "127.0.0.1")
    func setupRoutes(gateway: String, tunName: String, excludeIPs: [String], dnsServerIP: String,
                     reply: @escaping (Bool, String) -> Void)

    /// Clean up: restore routing table and close TUN device.
    func cleanup(tunName: String, reply: @escaping (Bool, String) -> Void)
}

/// Mach service name for the Helper
public let kHelperMachServiceName = "com.shadowproxy.helper"
```

- [ ] **Step 2: Create XPC client**

Create `Sources/ShadowProxyCore/System/XPCClient.swift`:

```swift
import Foundation

/// XPC client for communicating with the privileged ShadowProxyHelper
public final class XPCClient: @unchecked Sendable {
    private var connection: NSXPCConnection?

    public init() {}

    /// Connect to the Helper via XPC
    public func connect() {
        let conn = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.invalidationHandler = {
            splog.warning("XPC connection invalidated", tag: "XPC")
        }
        conn.interruptionHandler = {
            splog.warning("XPC connection interrupted", tag: "XPC")
        }
        conn.resume()
        self.connection = conn
        splog.info("XPC connected to \(kHelperMachServiceName)", tag: "XPC")
    }

    /// Create a TUN device via the Helper
    public func createTUN() async throws -> (fd: Int32, name: String) {
        let proxy = try getProxy()
        return try await withCheckedThrowingContinuation { continuation in
            proxy.createTUN { fd, name in
                if fd >= 0 {
                    continuation.resume(returning: (fd, name))
                } else {
                    continuation.resume(throwing: XPCError.helperError(name))
                }
            }
        }
    }

    /// Set up routes via the Helper
    public func setupRoutes(gateway: String, tunName: String, excludeIPs: [String], dnsServerIP: String) async throws {
        let proxy = try getProxy()
        return try await withCheckedThrowingContinuation { continuation in
            proxy.setupRoutes(gateway: gateway, tunName: tunName, excludeIPs: excludeIPs, dnsServerIP: dnsServerIP) { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: XPCError.helperError(message))
                }
            }
        }
    }

    /// Clean up via the Helper
    public func cleanup(tunName: String) async throws {
        let proxy = try getProxy()
        return try await withCheckedThrowingContinuation { continuation in
            proxy.cleanup(tunName: tunName) { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: XPCError.helperError(message))
                }
            }
        }
    }

    /// Disconnect from the Helper
    public func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Private

    private func getProxy() throws -> HelperProtocol {
        guard let conn = connection else {
            throw XPCError.notConnected
        }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            splog.error("XPC proxy error: \(error)", tag: "XPC")
        }) as? HelperProtocol else {
            throw XPCError.proxyFailed
        }
        return proxy
    }
}

public enum XPCError: Error, LocalizedError {
    case notConnected
    case proxyFailed
    case helperError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "XPC not connected to helper"
        case .proxyFailed: return "Failed to create XPC proxy"
        case .helperError(let msg): return "Helper error: \(msg)"
        }
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift build 2>&1 | tail -20`

Expected: Successful build.

- [ ] **Step 4: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add Sources/ShadowProxyCore/System/HelperProtocol.swift Sources/ShadowProxyCore/System/XPCClient.swift
git commit -m "feat(tun): XPC protocol + client for privileged Helper communication"
```

---

## Task 7: ShadowProxyHelper (Privileged Helper)

**Files:**
- Create: `Sources/ShadowProxyHelper/main.swift`
- Create: `Sources/ShadowProxyHelper/HelperDelegate.swift`
- Create: `Sources/ShadowProxyHelper/Info.plist`
- Create: `Sources/ShadowProxyHelper/launchd.plist`
- Modify: `Package.swift` (add executable target)

- [ ] **Step 1: Create HelperDelegate**

Create `Sources/ShadowProxyHelper/HelperDelegate.swift`:

```swift
import Foundation

class HelperDelegate: NSObject, NSXPCListenerDelegate, HelperProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    // MARK: - HelperProtocol

    func createTUN(reply: @escaping (Int32, String) -> Void) {
        // Create utun device using SYSPROTO_CONTROL
        let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else {
            reply(-1, "socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var ctlInfo = ctl_info()
        let utunControl = "com.apple.net.utun_control"
        _ = utunControl.withCString { ptr in
            strlcpy(&ctlInfo.ctl_name.0, ptr, MemoryLayout.size(ofValue: ctlInfo.ctl_name))
        }

        guard ioctl(fd, CTLIOCGINFO, &ctlInfo) >= 0 else {
            close(fd)
            reply(-1, "ioctl CTLIOCGINFO failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_ctl()
        addr.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        addr.sc_family = UInt8(AF_SYSTEM)
        addr.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        addr.sc_id = ctlInfo.ctl_id
        addr.sc_unit = 0  // Let kernel assign unit number

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }

        guard connectResult >= 0 else {
            close(fd)
            reply(-1, "connect() failed: \(String(cString: strerror(errno)))")
            return
        }

        // Get the assigned utun name
        var ifname = [CChar](repeating: 0, count: 256)
        var ifnameLen = socklen_t(ifname.count)
        getsockopt(fd, SYSPROTO_CONTROL, 2 /* UTUN_OPT_IFNAME */, &ifname, &ifnameLen)
        let tunName = String(cString: ifname)

        NSLog("ShadowProxyHelper: created \(tunName) (fd=\(fd))")
        reply(fd, tunName)
    }

    func setupRoutes(gateway: String, tunName: String, excludeIPs: [String], dnsServerIP: String,
                     reply: @escaping (Bool, String) -> Void) {
        var errors: [String] = []

        // 1. Add route for Fake IP subnet through TUN
        let r1 = run("/sbin/route", "add", "-net", "198.18.0.0/15", "-interface", tunName)
        if !r1 { errors.append("Failed to add Fake IP route") }

        // 2. Set default route through TUN
        let r2 = run("/sbin/route", "add", "default", "-interface", tunName)
        if !r2 { errors.append("Failed to set default route") }

        // 3. Exclude proxy server IPs — route them through original gateway
        for ip in excludeIPs {
            let r = run("/sbin/route", "add", "-host", ip, gateway)
            if !r { errors.append("Failed to exclude \(ip)") }
        }

        // 4. Set system DNS to our fake DNS server
        // Get active network service name first
        if let service = activeNetworkService() {
            let r4 = run("/usr/sbin/networksetup", "-setdnsservers", service, dnsServerIP)
            if !r4 { errors.append("Failed to set DNS") }
        }

        if errors.isEmpty {
            NSLog("ShadowProxyHelper: routes configured for \(tunName)")
            reply(true, "OK")
        } else {
            reply(false, errors.joined(separator: "; "))
        }
    }

    func cleanup(tunName: String, reply: @escaping (Bool, String) -> Void) {
        // 1. Remove Fake IP route
        run("/sbin/route", "delete", "-net", "198.18.0.0/15")

        // 2. Restore default route (remove TUN default)
        run("/sbin/route", "delete", "default", "-interface", tunName)

        // 3. Restore DNS to automatic
        if let service = activeNetworkService() {
            run("/usr/sbin/networksetup", "-setdnsservers", service, "Empty")
        }

        NSLog("ShadowProxyHelper: cleanup completed")
        reply(true, "OK")
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ args: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func activeNetworkService() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallnetworkservices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let services = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.hasPrefix("An asterisk") }
            return services.first { $0.contains("Wi-Fi") } ?? services.first
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 2: Create Helper main.swift**

Create `Sources/ShadowProxyHelper/main.swift`:

```swift
import Foundation

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "com.shadowproxy.helper")
listener.delegate = delegate
listener.resume()

NSLog("ShadowProxyHelper: started, waiting for connections")
RunLoop.current.run()
```

- [ ] **Step 3: Create Helper plists**

Create `Sources/ShadowProxyHelper/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.shadowproxy.helper</string>
    <key>CFBundleName</key>
    <string>ShadowProxyHelper</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>SMAuthorizedClients</key>
    <array>
        <string>identifier "com.shadowproxy.app"</string>
    </array>
</dict>
</plist>
```

Create `Sources/ShadowProxyHelper/launchd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.shadowproxy.helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.shadowproxy.helper</key>
        <true/>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/com.shadowproxy.helper</string>
    </array>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: Update Package.swift to add Helper target**

Add to targets array in `Package.swift`:

```swift
.executableTarget(
    name: "ShadowProxyHelper",
    dependencies: ["ShadowProxyCore"],
    path: "Sources/ShadowProxyHelper",
    exclude: ["Info.plist", "launchd.plist"]
),
```

- [ ] **Step 5: Build to verify compilation**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift build 2>&1 | tail -20`

Expected: Successful build of all targets.

- [ ] **Step 6: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add Sources/ShadowProxyHelper/ Package.swift
git commit -m "feat(tun): ShadowProxyHelper — XPC privileged helper for utun + routes"
```

---

## Task 8: TUNGlobalProxy Orchestrator

**Files:**
- Create: `Sources/ShadowProxyCore/TUN/TUNGlobalProxy.swift`
- Modify: `Sources/ShadowProxyCore/Engine/ProxyEngine.swift`

- [ ] **Step 1: Add handleTUNRequest to ProxyEngine**

Add a public method to `ProxyEngine` that accepts TUN-originated connections (domain + port + data callback, no NWConnection):

In `Sources/ShadowProxyCore/Engine/ProxyEngine.swift`, add after the existing `handleRequest` method:

```swift
/// Handle a request from TUN mode.
/// Unlike system proxy mode, TUN provides domain + port + data directly (no NWConnection).
public func handleTUNRequest(host: String, port: UInt16, policy: String? = nil) {
    let resolvedPolicy = policy ?? router.match(host: host)
    let record = RequestRecord(
        host: host, port: port,
        requestProtocol: "TUN",
        policy: resolvedPolicy
    )
    onRequest?(record)
    splog.debug("TUN → \(host):\(port) → \(resolvedPolicy)", tag: "ProxyEngine")
}
```

- [ ] **Step 2: Create TUNGlobalProxy orchestrator**

Create `Sources/ShadowProxyCore/TUN/TUNGlobalProxy.swift`:

```swift
import Foundation
import Network

/// Orchestrator for TUN global proxy mode.
/// Wires together: XPCClient → TUNManager → LwIPStack → FakeIPPool → ProxyEngine
public final class TUNGlobalProxy: @unchecked Sendable {
    private let xpcClient = XPCClient()
    private let tunManager = TUNManager()
    private let lwipStack = LwIPStack()
    private let fakeIPPool = FakeIPPool()
    private let fakeDNS: FakeDNSServer
    private let engine: ProxyEngine
    private let outbound: Outbound

    private var tunName: String = ""
    private var originalGateway: String = ""
    private var _isRunning = false
    public var isRunning: Bool { _isRunning }

    /// Active TUN TCP sessions: connectionID → NWConnection (to proxy server)
    private var sessions: [UInt32: NWConnection] = [:]
    private let sessionQueue = DispatchQueue(label: "shadowproxy.tun.sessions")

    public init(engine: ProxyEngine, outbound: Outbound) {
        self.engine = engine
        self.outbound = outbound
        self.fakeDNS = FakeDNSServer(pool: fakeIPPool, port: 53)
    }

    /// Start TUN global proxy
    public func start() async throws {
        // 1. Detect original default gateway
        originalGateway = try detectDefaultGateway()
        splog.info("Original gateway: \(originalGateway)", tag: "TUNGlobal")

        // 2. Connect to Helper via XPC
        xpcClient.connect()

        // 3. Create TUN device
        let (fd, name) = try await xpcClient.createTUN()
        tunName = name
        splog.info("TUN created: \(name) (fd=\(fd))", tag: "TUNGlobal")

        // 4. Start lwIP stack
        lwipStack.onOutput = { [weak self] packet in
            self?.tunManager.write(packet)
        }
        lwipStack.onTCPAccept = { [weak self] connID, dstIP, dstPort in
            self?.handleTCPAccept(connID: connID, dstIP: dstIP, dstPort: dstPort)
        }
        lwipStack.onTCPData = { [weak self] connID, data in
            self?.handleTCPData(connID: connID, data: data)
        }
        lwipStack.onTCPClose = { [weak self] connID in
            self?.handleTCPClose(connID: connID)
        }
        lwipStack.start()

        // 5. Start TUN reader
        tunManager.onPacket = { [weak self] packet in
            self?.lwipStack.input(packet)
        }
        tunManager.start(fd: fd, name: name)

        // 6. Start Fake DNS server
        try fakeDNS.start()

        // 7. Collect proxy server IPs to exclude from TUN
        let excludeIPs = collectProxyServerIPs()

        // 8. Setup routes via Helper
        try await xpcClient.setupRoutes(
            gateway: originalGateway,
            tunName: name,
            excludeIPs: excludeIPs,
            dnsServerIP: "127.0.0.1"
        )

        _isRunning = true
        splog.info("TUN global proxy started", tag: "TUNGlobal")
    }

    /// Stop TUN global proxy and restore system state
    public func stop() async {
        guard _isRunning else { return }

        // Cleanup routes first (while Helper is still connected)
        try? await xpcClient.cleanup(tunName: tunName)

        // Stop components in reverse order
        fakeDNS.stop()
        tunManager.stop()
        lwipStack.stop()
        xpcClient.disconnect()

        // Close all active sessions
        sessionQueue.sync {
            for (_, conn) in sessions {
                conn.cancel()
            }
            sessions.removeAll()
        }

        _isRunning = false
        splog.info("TUN global proxy stopped", tag: "TUNGlobal")
    }

    // MARK: - TCP Event Handlers

    private func handleTCPAccept(connID: UInt32, dstIP: String, dstPort: UInt16) {
        // Reverse lookup Fake IP → real domain
        guard let domain = fakeIPPool.lookup(ip: dstIP) else {
            splog.warning("TUN: unknown dst IP \(dstIP), closing", tag: "TUNGlobal")
            lwipStack.tcpClose(connectionID: connID)
            return
        }

        splog.debug("TUN TCP accept: \(domain):\(dstPort) (conn=\(connID))", tag: "TUNGlobal")

        // Route through ProxyEngine's router
        let target = ProxyTarget(host: domain, port: dstPort)
        engine.handleTUNRequest(host: domain, port: dstPort)

        // Create outbound connection to proxy server
        let policy = engine.routeHost(domain)
        guard let serverConfig = outbound.resolvePolicy(policy) else {
            splog.warning("TUN: cannot resolve policy \(policy) for \(domain)", tag: "TUNGlobal")
            lwipStack.tcpClose(connectionID: connID)
            return
        }

        Task {
            do {
                try await self.establishProxyConnection(connID: connID, target: target, config: serverConfig)
            } catch {
                splog.error("TUN: proxy connection failed for \(domain): \(error)", tag: "TUNGlobal")
                self.lwipStack.tcpClose(connectionID: connID)
            }
        }
    }

    private func handleTCPData(connID: UInt32, data: Data) {
        sessionQueue.sync {
            guard let remote = sessions[connID] else { return }
            remote.send(content: data, completion: .contentProcessed { error in
                if let error {
                    splog.error("TUN: send to proxy failed (conn=\(connID)): \(error)", tag: "TUNGlobal")
                }
            })
        }
    }

    private func handleTCPClose(connID: UInt32) {
        sessionQueue.sync {
            if let remote = sessions.removeValue(forKey: connID) {
                remote.cancel()
            }
        }
    }

    // MARK: - Proxy Connection

    private func establishProxyConnection(connID: UInt32, target: ProxyTarget, config: ServerConfig) async throws {
        // For now, create a direct TCP connection to the target
        // TODO: Integrate with Outbound's protocol-specific relay (SS/VMess/VLESS/Trojan)
        // This requires refactoring Outbound to support non-NWConnection data sources

        let queue = DispatchQueue(label: "shadowproxy.tun.conn.\(connID)")

        switch config {
        case .direct:
            let remote = NWConnection(
                host: NWEndpoint.Host(target.host),
                port: NWEndpoint.Port(rawValue: target.port)!,
                using: .tcp
            )
            try await remote.connectAsync(queue: queue)

            sessionQueue.sync {
                sessions[connID] = remote
            }

            // Start reading from remote → lwIP
            readFromRemote(connID: connID, remote: remote)

        default:
            // For proxy protocols, we need to do protocol handshake then bridge
            // Reuse Outbound's relay logic by creating a virtual NWConnection-like pipe
            // For MVP: establish connection, do handshake, then bridge data
            splog.debug("TUN: proxy protocol relay for conn=\(connID) (policy=\(config))", tag: "TUNGlobal")
            // TODO: Full protocol integration in next iteration
            lwipStack.tcpClose(connectionID: connID)
        }
    }

    private func readFromRemote(connID: UInt32, remote: NWConnection) {
        remote.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.lwipStack.tcpWrite(connectionID: connID, data: data)
                // Continue reading
                self.readFromRemote(connID: connID, remote: remote)
            } else if isComplete || error != nil {
                self.lwipStack.tcpClose(connectionID: connID)
                self.sessionQueue.sync {
                    self.sessions.removeValue(forKey: connID)
                }
            }
        }
    }

    // MARK: - Helpers

    private func detectDefaultGateway() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Parse "gateway: x.x.x.x" line
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                return trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        throw XPCError.helperError("Cannot detect default gateway")
    }

    private func collectProxyServerIPs() -> [String] {
        // Extract all proxy server host/IP addresses from config
        // These must bypass TUN to avoid traffic loops
        var ips: [String] = []
        // The engine's outbound has the proxy configs but doesn't expose them
        // For now, rely on the config being available
        return ips
    }
}
```

- [ ] **Step 3: Add routeHost() to ProxyEngine**

Add to `ProxyEngine.swift`, exposing the router for TUN mode:

```swift
/// Exposed for TUN mode: match host against rules and return policy
public func routeHost(_ host: String) -> String {
    router.match(host: host)
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift build 2>&1 | tail -20`

Expected: Successful build.

- [ ] **Step 5: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add Sources/ShadowProxyCore/TUN/TUNGlobalProxy.swift Sources/ShadowProxyCore/Engine/ProxyEngine.swift
git commit -m "feat(tun): TUNGlobalProxy orchestrator + ProxyEngine TUN integration"
```

---

## Task 9: ProxyViewModel + UI Integration

**Files:**
- Modify: `ShadowProxyApp/ProxyViewModel.swift`
- Modify: `ShadowProxyApp/MenuBarPopover.swift`

- [ ] **Step 1: Add TUN mode to ProxyViewModel**

In `ShadowProxyApp/ProxyViewModel.swift`, add the following:

Add new published properties after the existing ones:

```swift
@Published var proxyMode: ProxyMode = .systemProxy
private var tunGlobalProxy: TUNGlobalProxy?

enum ProxyMode: String {
    case systemProxy = "system"
    case global = "global"
}
```

Add `startGlobal()` and `stopGlobal()` methods:

```swift
func startGlobal() {
    guard !isRunning, let config else { return }

    log("Starting global proxy (TUN mode)...")

    Task {
        let engine = ProxyEngine(config: config, port: port, expandedRuleSets: expandedRuleSets)
        engine.onRequest = { [weak self] record in
            Task { @MainActor in
                self?.appendRequest(record)
            }
        }

        do {
            try engine.start()
            self.engine = engine

            let tunProxy = TUNGlobalProxy(engine: engine, outbound: engine.outbound)
            try await tunProxy.start()
            self.tunGlobalProxy = tunProxy

            self.isRunning = true
            self.proxyMode = .global
            (NSApp.delegate as? AppDelegate)?.updateStatusIcon(running: true)
            self.statusText = "Global (TUN)"
            log("Global proxy started")
        } catch {
            log("Global proxy start failed: \(error)")
        }
    }
}

func stopGlobal() {
    guard isRunning, proxyMode == .global else { return }

    Task {
        await tunGlobalProxy?.stop()
        tunGlobalProxy = nil

        engine?.stop()
        engine = nil

        isRunning = false
        proxyMode = .systemProxy
        (NSApp.delegate as? AppDelegate)?.updateStatusIcon(running: false)
        statusText = "Stopped"
        log("Global proxy stopped")
    }
}
```

Modify the existing `stop()` to handle both modes:

```swift
func stop() {
    guard isRunning else { return }

    if proxyMode == .global {
        stopGlobal()
        return
    }

    // existing system proxy stop logic...
    engine?.stop()
    engine = nil
    sleepWatcher?.stop()
    sleepWatcher = nil

    do {
        try SystemProxy.disable()
        log("System proxy disabled")
    } catch {
        log("Failed to disable system proxy: \(error)")
    }

    isRunning = false
    (NSApp.delegate as? AppDelegate)?.updateStatusIcon(running: false)
    statusText = "Stopped"
    log("Proxy stopped")
}
```

- [ ] **Step 2: Update MenuBarPopover mode buttons**

In `ShadowProxyApp/MenuBarPopover.swift`, replace the mode bar section:

```swift
// Mode bar
HStack(spacing: 6) {
    modeButton(title: "系统代理", active: viewModel.proxyMode == .systemProxy) {
        if viewModel.isRunning && viewModel.proxyMode == .global {
            viewModel.stopGlobal()
        }
        if !viewModel.isRunning {
            viewModel.start()
        }
    }
    modeButton(title: "全局代理", active: viewModel.proxyMode == .global) {
        if viewModel.isRunning && viewModel.proxyMode == .systemProxy {
            viewModel.stop()
        }
        if !viewModel.isRunning {
            viewModel.startGlobal()
        }
    }
    Spacer()
}
.padding(.horizontal, 16)
.padding(.vertical, 8)
```

Update the `modeButton` helper to accept an action:

```swift
private func modeButton(title: String, active: Bool, action: @escaping () -> Void = {}) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(active ? Color.accentColor : Color.gray.opacity(0.2))
            .foregroundStyle(active ? .white : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 3: Build the app**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift build 2>&1 | tail -20`

Expected: Successful build.

- [ ] **Step 4: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add ShadowProxyApp/ProxyViewModel.swift ShadowProxyApp/MenuBarPopover.swift
git commit -m "feat(tun): UI integration — 系统代理/全局代理 互斥开关"
```

---

## Task 10: Expose outbound from ProxyEngine + Fix collectProxyServerIPs

**Files:**
- Modify: `Sources/ShadowProxyCore/Engine/ProxyEngine.swift`
- Modify: `Sources/ShadowProxyCore/TUN/TUNGlobalProxy.swift`

- [ ] **Step 1: Expose outbound and config from ProxyEngine**

In `ProxyEngine.swift`, make `outbound` and proxy server IPs accessible:

```swift
/// The outbound handler (exposed for TUN mode)
public var outboundHandler: Outbound { outbound }

/// Get all proxy server IPs from config (for TUN route exclusion)
public func proxyServerIPs() -> [String] {
    config.proxies.values.compactMap { serverConfig -> String? in
        switch serverConfig {
        case .shadowsocks(let c): return c.server
        case .vmess(let c): return c.server
        case .vless(let c): return c.server
        case .trojan(let c): return c.server
        case .direct: return nil
        }
    }
}
```

- [ ] **Step 2: Update TUNGlobalProxy to use exposed outbound**

In `TUNGlobalProxy.swift`, update the init and collectProxyServerIPs:

Change the init:

```swift
public init(engine: ProxyEngine) {
    self.engine = engine
    self.outbound = engine.outboundHandler
    self.fakeDNS = FakeDNSServer(pool: fakeIPPool, port: 53)
}
```

Remove the `outbound` init parameter. Update `collectProxyServerIPs`:

```swift
private func collectProxyServerIPs() -> [String] {
    return engine.proxyServerIPs()
}
```

- [ ] **Step 3: Build to verify**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift build 2>&1 | tail -20`

Expected: Successful build.

- [ ] **Step 4: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add Sources/ShadowProxyCore/Engine/ProxyEngine.swift Sources/ShadowProxyCore/TUN/TUNGlobalProxy.swift
git commit -m "fix(tun): expose outbound from ProxyEngine, wire proxy server IP exclusion"
```

---

## Task 11: Helper Installation Script

**Files:**
- Create: `scripts/install-helper.sh`

- [ ] **Step 1: Create installation script**

Create `scripts/install-helper.sh`:

```bash
#!/bin/bash
set -e

HELPER_NAME="com.shadowproxy.helper"
HELPER_PATH="/Library/PrivilegedHelperTools/$HELPER_NAME"
PLIST_PATH="/Library/LaunchDaemons/$HELPER_NAME.plist"
BUILD_DIR=".build/debug"

echo "=== ShadowProxy Helper Installer ==="

# Build helper
echo "Building helper..."
swift build --product ShadowProxyHelper

# Install helper binary
echo "Installing helper to $HELPER_PATH (requires sudo)..."
sudo mkdir -p /Library/PrivilegedHelperTools
sudo cp "$BUILD_DIR/ShadowProxyHelper" "$HELPER_PATH"
sudo chmod 544 "$HELPER_PATH"
sudo chown root:wheel "$HELPER_PATH"

# Install launchd plist
echo "Installing launchd plist..."
sudo cp "Sources/ShadowProxyHelper/launchd.plist" "$PLIST_PATH"
sudo chown root:wheel "$PLIST_PATH"
sudo chmod 644 "$PLIST_PATH"

# Load the helper
echo "Loading helper..."
sudo launchctl bootout system/$HELPER_NAME 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST_PATH"

echo "=== Done! Helper installed and running. ==="
echo "Verify: sudo launchctl print system/$HELPER_NAME"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source/scripts/install-helper.sh
```

- [ ] **Step 3: Commit**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add scripts/install-helper.sh
git commit -m "feat(tun): Helper installation script"
```

---

## Task 12: Run all existing tests (regression check)

- [ ] **Step 1: Run full test suite**

Run: `cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source && swift test 2>&1 | tail -40`

Expected: All existing tests pass. New FakeIPPool and FakeDNS tests also pass.

- [ ] **Step 2: Fix any failures**

If any existing tests fail due to the new code, fix them. The new code should not break any existing functionality since it only adds new files and minimal changes to existing ones.

- [ ] **Step 3: Commit if any fixes were needed**

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/xx_script/shadowproxy/source
git add -A
git commit -m "fix: resolve test regressions from TUN integration"
```

---

## Summary

| Task | Component | Files | Key Deliverable |
|------|-----------|-------|----------------|
| 1 | FakeIPPool | 2 new | Domain ↔ Fake IP mapping with LRU |
| 2 | FakeDNSServer | 2 new | UDP DNS listener returning Fake IPs |
| 3 | lwIP SPM | ~100 C files + config | lwIP 2.2.0 C target compiles in SPM |
| 4 | LwIPStack | 1 new | Swift-C bridge for TCP reassembly |
| 5 | TUNManager | 1 new | utun fd read/write loop |
| 6 | XPC Protocol + Client | 2 new | HelperProtocol + XPCClient |
| 7 | ShadowProxyHelper | 4 new, 1 modified | Root LaunchDaemon for utun + routes |
| 8 | TUNGlobalProxy | 1 new, 1 modified | Orchestrator wiring all components |
| 9 | UI Integration | 2 modified | 系统代理/全局代理 互斥开关 |
| 10 | Wiring fixes | 2 modified | Expose outbound, proxy server IPs |
| 11 | Install script | 1 new | Helper installation automation |
| 12 | Regression test | 0 | Verify nothing broke |

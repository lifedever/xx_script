import XCTest
@testable import BoxX

final class ClashAPITests: XCTestCase {
    let api = ClashAPI(baseURL: "http://127.0.0.1:9091")

    func testGetProxies() async throws {
        let groups = try await api.getProxies()
        XCTAssertFalse(groups.isEmpty)
        XCTAssertTrue(groups.contains(where: { $0.name == "Proxy" }))
    }

    func testGetRules() async throws {
        let rules = try await api.getRules()
        XCTAssertFalse(rules.isEmpty)
    }

    func testGetConnections() async throws {
        let snapshot = try await api.getConnections()
        XCTAssertGreaterThanOrEqual(snapshot.downloadTotal, 0)
    }

    func testGetDelay() async throws {
        let delay = try await api.getDelay(name: "DIRECT", url: "http://www.gstatic.com/generate_204", timeout: 5000)
        XCTAssertGreaterThan(delay, 0)
    }
}

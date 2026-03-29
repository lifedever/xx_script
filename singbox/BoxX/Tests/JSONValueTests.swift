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

    func testBoolNotDecodedAsNumber() throws {
        let json = """
        {"flag":true,"count":1}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(JSONValue.self, from: json)
        XCTAssertEqual(decoded["flag"]?.boolValue, true)
        XCTAssertNil(decoded["flag"]?.numberValue)  // Should NOT be decoded as number
        XCTAssertEqual(decoded["count"]?.numberValue, 1)
    }
}

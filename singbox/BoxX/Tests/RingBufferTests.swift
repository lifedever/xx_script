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
        buf.append(1); buf.append(2); buf.append(3); buf.append(4)
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
        buf.append(1); buf.append(2)
        buf.removeAll()
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(Array(buf), [])
    }
}

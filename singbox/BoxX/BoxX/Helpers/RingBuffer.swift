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
        if _count < capacity { _count += 1 }
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

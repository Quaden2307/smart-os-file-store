import Synchronization

/// Values collected from callbacks that run on other threads, in the order they arrived.
final class ConcurrentLog<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    var values: [Element] {
        storage.withLock { $0 }
    }
}

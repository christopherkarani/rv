import Synchronization

/// Portable exclusive lock for the Service door.
/// `Mutex` is `~Copyable`, so the wrap is a class.
package final class UnfairLock<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    package init(_ initial: Value) {
        storage = Mutex(initial)
    }

    package func withLock<Result>(
        _ body: (inout sending Value) throws -> sending Result
    ) rethrows -> Result {
        try storage.withLock(body)
    }
}

import Foundation

/// Blocking I/O (a socket round trip that waits in `recv`) kept off the
/// cooperative pool. The pool has one thread per core and never grows when
/// one blocks: an `events` long poll, or any request waiting on rvd, run
/// there would pin a pool thread for its whole wait and starve unrelated
/// tasks. `run` does the work on a thread of its own and suspends the
/// caller until it finishes.
enum BlockingIO {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let result: Result<T, any Error> = await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: Result(catching: body)) }
        }
        return try result.get()
    }
}

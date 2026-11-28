import Foundation

/// Runs blocking work (a socket read, a semaphore wait, a sleep) on a thread
/// of its own and suspends the calling task until it finishes.
///
/// Swift Testing runs tests on the cooperative pool, which has one thread
/// per core (three on a macOS CI runner) and never grows when one blocks. A
/// test that blocks a pool thread waiting for an in-process listener, whose
/// reply comes from a `Task`, needs a free pool thread to be answered. Three
/// such tests at once leave none, and the whole run stalls until timeouts
/// fire, starving every timing-sensitive test meanwhile. Blocking here keeps
/// the pool free.
func offPool<T: Sendable, E: Error>(
    _ body: @escaping @Sendable () throws(E) -> T
) async throws(E) -> T {
    let result: Result<T, E> = await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: Result(catching: body))
        }
    }
    return try result.get()
}

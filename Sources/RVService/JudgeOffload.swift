import Dispatch

/// Runs synchronous judge work (model load wait, CoreML inference, the
/// script check's file reads) on a Dispatch queue instead of the caller's
/// thread.
///
/// The judge path blocks: a cold load can hold a caller up to
/// `JudgeRuntime.loadWait` (5 s in rvd) and inference serializes on the
/// model. On the Swift cooperative pool (one thread per core), a handful of
/// concurrent cold hooks would park every pool thread, stalling Hello, the
/// idle watchdog and every other request until the load lands. A queue
/// gets its own threads; the awaiting task suspends and frees its pool
/// thread (or its actor) meanwhile.
enum JudgeOffload {
    private static let queue = DispatchQueue(
        label: "rv.judge", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

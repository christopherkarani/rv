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
///
/// The calling task's hook deadline is carried into `body` as
/// `JudgeAdmission.deadline`, so the judge stops waiting for the model once
/// the client has given up.
enum JudgeOffload {
    private static let queue = DispatchQueue(
        label: "rv.judge", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let deadline = HookDeadline.current?.expiresAt
        // `HookTiming` is task-local too: rebind it on the queue thread and
        // count the wait for that thread.
        let timing = HookTiming.current
        let enqueued = ContinuousClock.now
        return await withCheckedContinuation { continuation in
            queue.async {
                timing?.add(.offloadWait, ContinuousClock.now - enqueued)
                let result = HookTiming.$current.withValue(timing) {
                    JudgeAdmission.$deadline.withValue(deadline) { body() }
                }
                continuation.resume(returning: result)
            }
        }
    }
}

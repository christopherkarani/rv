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
/// Two deadlines go into `body`, and they differ on purpose:
/// - `JudgeAdmission.deadline` bounds the judge only: the calling task's
///   hook deadline, or else `judgeBudget` counted from when `body` starts
///   (rvd's non-hook doors). Anchoring at body start keeps time the task
///   spent waiting for the pool or this queue out of the judge's budget.
/// - `hookDeadline` is the hook deadline alone. Pattern search reads it, so
///   only an evaluation whose hook client has given up stops searching; a
///   non-hook evaluation keeps `PatternBudget`'s own ceiling.
enum JudgeOffload {
    private static let queue = DispatchQueue(
        label: "rv.judge", qos: .userInitiated, attributes: .concurrent)

    /// The judge budget rvd's non-hook doors bind (SDK evaluate, explain,
    /// classify, the agent bridge, approval-path peeks): one hook budget,
    /// so a stuck prediction answers `late` (review) at about
    /// `nonHookBudget - JudgeAdmission.replyMargin` instead of holding the
    /// caller, a model slot, or the circuit's half-open trial.
    static let nonHookBudget: Duration = HookDeadline.budget

    /// A judge budget for a caller with no hook deadline. Read only by
    /// `run`; a hook deadline wins over it.
    @TaskLocal static var judgeBudget: Duration?

    /// The hook deadline of the request `body` serves, if any. `run` binds
    /// it on the Dispatch thread, where `HookDeadline.current` is not
    /// visible. Never a non-hook judge budget.
    @TaskLocal static var hookDeadline: ContinuousClock.Instant?

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let hook = HookDeadline.current?.expiresAt
        let budget = judgeBudget
        return await withCheckedContinuation { continuation in
            queue.async {
                let judge = hook ?? budget.map { ContinuousClock.now.advanced(by: $0) }
                let value = $hookDeadline.withValue(hook) {
                    JudgeAdmission.$deadline.withValue(judge) { body() }
                }
                continuation.resume(returning: value)
            }
        }
    }
}

import RVHistory
import Synchronization

/// One hook call as it runs: its `DecisionStamp` (the id its ledger and
/// decision-log rows share) and the would-be verdict noted while it is
/// evaluated. Bound as a task-local around one call, at rvd's hook point
/// (`ServiceRuntime`) and around each hook-local evaluation, so
/// `GatedEvaluate` stamps the ledger row and notes what watch mode let
/// run, and `DecisionLogRecorder` reads both for the decision row.
final class DecisionCall: Sendable {
    @TaskLocal static var current: DecisionCall?

    let stamp: DecisionStamp
    private let noted = Mutex<DecisionWouldBe?>(nil)

    init(stamp: DecisionStamp = DecisionStamp()) {
        self.stamp = stamp
    }

    var id: String { stamp.id }

    /// The would-be verdict noted during this call, if any.
    var wouldBe: DecisionWouldBe? {
        noted.withLock { $0 }
    }

    /// Notes what guarding would have done (an observed would-be row).
    func note(_ wouldBe: DecisionWouldBe) {
        noted.withLock { $0 = wouldBe }
    }
}

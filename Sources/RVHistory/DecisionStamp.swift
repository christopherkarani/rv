import Foundation
import Synchronization

/// What guarding would have done with a command watch mode let run: the
/// observed would-be verdict, as the denial ledger's observed row has it.
public struct DecisionWouldBe: Sendable, Equatable, Codable {
    /// `denied` for a rule, `refused` when rv could not finish deciding.
    public var verdict: DecisionVerdict
    /// The rule (or `rv.indeterminate:` reason) guarding would have cited.
    public var rule: String
    /// Guarding would have asked a human rather than stopped it.
    public var ask: Bool

    public init(verdict: DecisionVerdict, rule: String, ask: Bool = false) {
        self.verdict = verdict
        self.rule = rule
        self.ask = ask
    }
}

/// One hook decision's id, minted once before evaluation, and the would-be
/// verdict noted while it runs. Bound as a task-local around one evaluation
/// (rvd's `HookEvaluateWorld.live`, the hook-local evaluator), so the
/// denial-ledger row and the decision-log row for that call carry the same
/// id, and the decision row learns what watch mode let run.
public final class DecisionStamp: Sendable {
    @TaskLocal public static var current: DecisionStamp?

    /// 12 lowercase hex digits. `rv log` shows the first six as its code.
    public let id: String
    private let noted = Mutex<DecisionWouldBe?>(nil)

    public init(id: String = DecisionStamp.mintID()) {
        self.id = id
    }

    /// The would-be verdict noted during this evaluation, if any.
    public var wouldBe: DecisionWouldBe? {
        noted.withLock { $0 }
    }

    /// Notes what guarding would have done (an observed would-be row).
    public func note(_ wouldBe: DecisionWouldBe) {
        noted.withLock { $0 = wouldBe }
    }

    /// A fresh random id: 48 bits, so rows in the 7-day window do not
    /// share one.
    public static func mintID() -> String {
        let value = UInt64.random(in: 0..<(1 << 48))
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 12 - hex.count) + hex
    }

    /// `a7c-835`: the code `rv log` prints for an id.
    public static func code(forID id: String) -> String {
        String(id.prefix(3)) + "-" + String(id.dropFirst(3).prefix(3))
    }
}

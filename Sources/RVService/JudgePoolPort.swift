import Foundation
import RVDomain
import RVJudgePool
import RVLaya
import RVPolicy

/// rvd's route to the judge: the supervised worker pool behind
/// `dev.rv.judge` (docs/architecture/judge-pool.md). rvd never loads Core ML
/// itself once a client is bound; the in-process judge stays for the CLI
/// (`rv test`, bench), which has no pool and no hook deadline.
///
/// Every answer that is not an authenticated, well-formed verdict fails
/// closed to review, a worker's load failure included: rvd only calls the
/// pool once it found the bundle on disk (absent is `engine-missing`,
/// decided before), and a load that then fails can be induced (a full disk,
/// a corrupt compile cache). The packs-only floor would make that an
/// unjudged allow. Doctor's `judgePool` check names the load failure.
extension JudgeRuntime {
    private static let clientBox = UnfairLock<(any JudgeClient)?>(nil)

    /// The pool client rvd binds at startup on macOS. Nil keeps the
    /// in-process judge (CLI, tests, Linux).
    static var boundClient: (any JudgeClient)? { clientBox.withLock { $0 } }

    public static func bindClient(_ client: (any JudgeClient)?) {
        clientBox.withLock { $0 = client }
    }

    /// Time kept back from the hook deadline for the XPC round trip and the
    /// reply back to the hook.
    static let poolDeadlineSlack: Duration = .milliseconds(400)

    /// The pool's budget for one request: the pool's own budget, shortened
    /// to what the hook deadline leaves. Nil when nothing is left.
    static func poolBudget(
        deadline: ContinuousClock.Instant?,
        now: ContinuousClock.Instant = .now,
        cap: Duration = PoolPolicy.live.budget
    ) -> Duration? {
        guard let deadline else { return cap }
        let left = deadline - now - poolDeadlineSlack - JudgePoolWire.transportSlack
        guard left >= .milliseconds(1) else { return nil }
        return min(cap, left)
    }

    /// One judged call through the pool.
    static func runPool(
        _ call: JudgeCall,
        client: any JudgeClient,
        deadline: ContinuousClock.Instant? = JudgeAdmission.deadline,
        now: ContinuousClock.Instant = .now
    ) -> JudgeRun {
        guard let budget = poolBudget(deadline: deadline, now: now) else { return .late }
        let key = ModelKey(engine: call.engine.rawValue, bundle: call.bundle.path)
        let input = JudgeInput(command: call.command, contextLines: call.context.lines())
        return read(client.judge(key: key, input: input, budget: budget))
    }

    /// The pool's answer as a judge run. Nil is the client's "no
    /// authenticated answer" (unreachable, refused, unverifiable, past the
    /// deadline).
    static func read(_ outcome: PoolOutcome?) -> JudgeRun {
        guard let outcome else { return .unreachable }
        switch outcome {
        case .verdict(let data, _):
            guard let verdict = JudgePoolJSON.decode(LayaVerdict.self, from: data),
                  wellFormed(verdict) else { return .failed }
            return .verdict(verdict)
        case .busy: return .busy
        case .late: return .late
        case .warming: return .warming
        case .loadFailed(let failure):
            return .refused("Laya judge pool could not load the model (\(failure.message)); judged calls go to review. Run `rv doctor`.")
        case .failed: return .failed
        }
    }

    /// A verdict the thresholds can read: every probability present, every
    /// score finite and in [0, 1]. A missing probability would read as 0
    /// and a NaN risk compares false against every threshold (fail-open).
    static func wellFormed(_ verdict: LayaVerdict) -> Bool {
        let unit: (Double) -> Bool = { $0.isFinite && (0...1).contains($0) }
        let actions: [LayaVerdict.Action] = [.allow, .review, .block]
        return verdict.probabilities.count == actions.count
            && actions.allSatisfy { verdict.probabilities[$0].map(unit) ?? false }
            && unit(verdict.risk) && unit(verdict.riskScore) && unit(verdict.malicious)
            && verdict.latencyMilliseconds.isFinite
    }

    /// Starts the pool's workers on the model this home would run.
    static func warmPool(_ client: any JudgeClient, home: HomeDirectory?) {
        guard let resolved = resolvedJudge(home: home, config: GuardConfig.read(home: home)) else { return }
        client.warm(key: ModelKey(engine: resolved.engine.rawValue, bundle: resolved.bundle.path))
    }

    /// Doctor: whether rvd routes through the pool and, if so, the
    /// supervisor's status (nil when it did not answer). Blocks up to
    /// `timeout`: call it off the actor (`JudgeOffload.run`).
    static func poolProbe(timeout: Duration = .milliseconds(500)) -> JudgePoolProbe {
        guard let client = boundClient else { return JudgePoolProbe(bound: false, status: nil) }
        return JudgePoolProbe(bound: true, status: client.status(timeout: timeout))
    }
}

/// What doctor knows about the pool: `bound` is false when rvd runs the
/// in-process judge (Linux, CLI), so there is no pool to report.
public struct JudgePoolProbe: Sendable, Equatable {
    public let bound: Bool
    public let status: PoolStatus?

    public init(bound: Bool, status: PoolStatus?) {
        self.bound = bound
        self.status = status
    }

    /// rvd runs the judge in-process: nothing to report.
    public static let unbound = JudgePoolProbe(bound: false, status: nil)
}

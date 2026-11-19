import Foundation
import RVDomain
import RVIPC
import RVJudgePool
import RVLaya
import Synchronization
import Testing
@testable import RVService

/// A pool client with a fixed answer that records what it was asked.
private final class FixedPoolClient: JudgeClient, Sendable {
    let outcome: PoolOutcome?
    let status: PoolStatus?
    private let calls = Mutex<[(ModelKey, JudgeInput, Duration)]>([])

    init(_ outcome: PoolOutcome?, status: PoolStatus? = nil) {
        self.outcome = outcome
        self.status = status
    }

    var budgets: [Duration] { calls.withLock { $0.map(\.2) } }
    var keys: [ModelKey] { calls.withLock { $0.map(\.0) } }
    var inputs: [JudgeInput] { calls.withLock { $0.map(\.1) } }

    func judge(key: ModelKey, input: JudgeInput, budget: Duration) -> PoolOutcome? {
        calls.withLock { $0.append((key, input, budget)) }
        return outcome
    }

    func warm(key: ModelKey) {}

    func status(timeout: Duration) -> PoolStatus? { status }
}

private func verdictJSON(
    choice: String = "allow", risk: String = "0.1", probabilities: String? = nil, malicious: String = "0"
) -> Data {
    let probs = probabilities ?? #"{"allow":0.9,"review":0.05,"block":0.05}"#
    return Data("""
    {"choice":"\(choice)","probabilities":\(probs),"riskScore":\(risk),"malicious":\(malicious),
     "risk":\(risk),"checkpoint":"ft-test","latencyMilliseconds":12,"truncated":false}
    """.utf8)
}

private let call = JudgeCall(
    command: "npm install left-pad", context: JudgeContext(cwdInsideRepo: true),
    engine: .ft, bundle: URL(fileURLWithPath: "/models/laya-ft-v2-coreml", isDirectory: true))

@Suite("Judge pool port: rvd's mapping of pool answers")
struct JudgePoolPortTests {
    @Test("no authenticated answer is unreachable, which fails closed to review")
    func unreachableFailsClosed() {
        guard case .unreachable = JudgeRuntime.read(nil) else {
            Issue.record("nil must map to unreachable")
            return
        }
        let allow = EvaluationResult(outcome: .plain, matchingView: "npm install left-pad", analysis: .unknown)
        let reading = JudgeRuntime.read(.unreachable, over: allow, provenance: .userTyped)
        guard case .deny(let deny) = reading.outcome.decision else {
            Issue.record("unreachable judge must not allow")
            return
        }
        #expect(deny.ruleID.rawValue == "core.judge:laya-review")
        #expect(reading.note == "judge-unreachable")
        #expect(reading.action == .review)
    }

    @Test("busy, late, warming and failed all fail closed to review", arguments: [
        PoolOutcome.busy, .late, .warming, .failed("worker crashed"),
    ])
    func nonVerdictsFailClosed(outcome: PoolOutcome) {
        let run = JudgeRuntime.read(outcome)
        let allow = EvaluationResult(outcome: .plain, matchingView: "x", analysis: .unknown)
        let reading = JudgeRuntime.read(run, over: allow, provenance: .userTyped)
        guard case .deny = reading.outcome.decision else {
            Issue.record("\(outcome) must not allow")
            return
        }
        #expect(reading.action == .review)
    }

    @Test("the fail-closed notes name the pool outcome")
    func notes() {
        let allow = EvaluationResult(outcome: .plain, matchingView: "x", analysis: .unknown)
        #expect(JudgeRuntime.failClosed(.late, over: allow).note == "judge-late")
        #expect(JudgeRuntime.failClosed(.unreachable, over: allow).note == "judge-unreachable")
        #expect(JudgeRuntime.failClosed(.busy, over: allow).note == "judge-busy")
    }

    @Test("an authenticated load failure is the broken-install case: packs-only")
    func loadFailureIsUnavailable() {
        guard case .unavailable(let note) = JudgeRuntime.read(
            .loadFailed(LoadFailure(kind: .badBundle, message: "tokenizer missing"))) else {
            Issue.record("load failure must map to unavailable")
            return
        }
        #expect(note == "tokenizer missing")
    }

    @Test("a well-formed verdict is read")
    func verdictDecodes() throws {
        guard case .verdict(let verdict) = JudgeRuntime.read(.verdict(verdictJSON(), slot: .primary)) else {
            Issue.record("a well-formed verdict must decode")
            return
        }
        #expect(verdict.checkpoint == "ft-test")
        #expect(verdict.choice == .allow)
    }

    @Test("a malformed or out-of-range verdict is a prediction failure, never an allow", arguments: [
        Data("not json".utf8),
        verdictJSON(probabilities: #"{"allow":1}"#),
        verdictJSON(probabilities: #"{"allow":0.9,"review":0.05,"block":-0.1}"#),
        verdictJSON(risk: "1.5"),
        verdictJSON(risk: "-0.01"),
        verdictJSON(malicious: "2"),
        verdictJSON(choice: "maybe"),
    ])
    func malformedVerdictFails(data: Data) {
        guard case .failed = JudgeRuntime.read(.verdict(data, slot: .fallback)) else {
            Issue.record("malformed verdict must map to failed")
            return
        }
    }

    @Test("runPool sends the engine, bundle, context lines and a budget capped by the pool's")
    func runPoolRequest() {
        let client = FixedPoolClient(.verdict(verdictJSON(), slot: .primary))
        let now = ContinuousClock.now
        guard case .verdict = JudgeRuntime.runPool(call, client: client, deadline: now + .seconds(8), now: now) else {
            Issue.record("expected a verdict")
            return
        }
        #expect(client.keys == [ModelKey(engine: "ft", bundle: "/models/laya-ft-v2-coreml")])
        #expect(client.inputs == [JudgeInput(command: "npm install left-pad", contextLines: call.context.lines())])
        #expect(client.budgets == [PoolPolicy.live.budget])
    }

    @Test("the budget shrinks to the hook deadline, and an exhausted deadline is late without asking")
    func budgetFollowsDeadline() {
        let now = ContinuousClock.now
        let slack = JudgeRuntime.poolDeadlineSlack + JudgePoolWire.transportSlack
        #expect(JudgeRuntime.poolBudget(deadline: nil, now: now) == PoolPolicy.live.budget)
        #expect(JudgeRuntime.poolBudget(deadline: now + slack + .milliseconds(300), now: now) == .milliseconds(300))
        #expect(JudgeRuntime.poolBudget(deadline: now + slack, now: now) == nil)

        let client = FixedPoolClient(.verdict(verdictJSON(), slot: .primary))
        guard case .late = JudgeRuntime.runPool(call, client: client, deadline: now + slack, now: now) else {
            Issue.record("no time left must be late")
            return
        }
        #expect(client.budgets.isEmpty)
    }

    @Test("doctor: no pool bound reports nothing; an unreachable pool is a warning")
    func doctorUnreachable() throws {
        #expect(DoctorSnapshotBuilder.judgePoolCheck(JudgePoolProbe(bound: false, status: nil)) == nil)
        let check = try #require(DoctorSnapshotBuilder.judgePoolCheck(JudgePoolProbe(bound: true, status: nil)))
        #expect(check.id == .judgePool)
        #expect(check.status == .warning)
        #expect(check.message.contains("go to review"))
        #expect(check.message.contains("judge"))
    }

    @Test("doctor: workers, compute units, restarts and routing; degraded is a warning")
    func doctorStatus() throws {
        func status(degradedA: Bool) -> PoolStatus {
            PoolStatus(
                protocolVersion: 1, engine: "ft",
                workers: [
                    .init(slot: .primary, compute: "accelerated", phase: degradedA ? "down" : "idle",
                          restarts: 3, recentFaults: degradedA ? 3 : 0, degraded: degradedA, loadFailure: nil),
                    .init(slot: .fallback, compute: "cpu", phase: "idle",
                          restarts: 0, recentFaults: 0, degraded: false, loadFailure: nil),
                ],
                queued: 0, served: 10, hedged: 2, hedgeWins: 1, killed: 1, late: 0, refusedBusy: 0)
        }
        let healthy = try #require(DoctorSnapshotBuilder.judgePoolCheck(JudgePoolProbe(bound: true, status: status(degradedA: false))))
        #expect(healthy.status == .ok)
        #expect(healthy.message.contains("A accelerated idle, restarts 3"))
        #expect(healthy.message.contains("B cpu idle, restarts 0"))
        #expect(healthy.message.contains("routing hedged"))
        let degraded = try #require(DoctorSnapshotBuilder.judgePoolCheck(JudgePoolProbe(bound: true, status: status(degradedA: true))))
        #expect(degraded.status == .warning)
        #expect(degraded.message.contains("cpu-only"))
    }
}

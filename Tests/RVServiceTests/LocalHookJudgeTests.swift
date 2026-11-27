import Foundation
import RVDomain
import RVJudgePool
import RVLaya
import RVPolicy
import Synchronization
import Testing
@testable import RVService

/// A pool client with fixed scores: each command always gets the same
/// verdict, so the evaluator and rvd see the same answer. Records every
/// request, and can stand in for a pool that never answers.
final class ScoredPoolClient: JudgeClient, Sendable {
    enum Answer: Sendable {
        /// allow / review / block by a stable hash of the command.
        case scored
        case fixed(choice: String)
        case outcome(PoolOutcome?)
        /// Holds the call for the client's worst case (`budget` plus the
        /// transport slack), then answers nil.
        case silent
    }

    let answer: Answer
    private let calls = Mutex<[(input: JudgeInput, budget: Duration, at: ContinuousClock.Instant)]>([])

    init(_ answer: Answer = .scored) {
        self.answer = answer
    }

    var budgets: [Duration] { calls.withLock { $0.map(\.budget) } }
    /// When each request reached the client.
    var instants: [ContinuousClock.Instant] { calls.withLock { $0.map(\.at) } }
    var count: Int { calls.withLock { $0.count } }

    func judge(key: ModelKey, input: JudgeInput, budget: Duration) -> PoolOutcome? {
        calls.withLock { $0.append((input, budget, .now)) }
        switch answer {
        case .scored:
            return .verdict(Self.verdict(Self.choice(input.command)), slot: .primary)
        case .fixed(let choice):
            return .verdict(Self.verdict(choice), slot: .primary)
        case .outcome(let outcome):
            return outcome
        case .silent:
            Thread.sleep(forTimeInterval: Self.seconds(budget + JudgePoolWire.transportSlack))
            return nil
        }
    }

    func warm(key: ModelKey) {}
    func status(timeout: Duration) -> PoolStatus? { nil }

    /// 7 in 10 allow, 2 review, 1 block.
    static func choice(_ command: String) -> String {
        switch command.utf8.reduce(0, { ($0 &* 31 &+ Int($1)) & 0xFFFF }) % 10 {
        case 0...6: "allow"
        case 7...8: "review"
        default: "block"
        }
    }

    static func verdict(_ choice: String) -> Data {
        let (probabilities, risk) = switch choice {
        case "block": (#"{"allow":0.02,"review":0.08,"block":0.9}"#, "0.95")
        case "review": (#"{"allow":0.1,"review":0.8,"block":0.1}"#, "0.6")
        default: (#"{"allow":0.97,"review":0.02,"block":0.01}"#, "0.02")
        }
        return Data("""
            {"choice":"\(choice)","probabilities":\(probabilities),"riskScore":\(risk),"malicious":0,
             "risk":\(risk),"checkpoint":"ft-test","latencyMilliseconds":12,"truncated":false}
            """.utf8)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// rvd's judge over a pool client: exactly `LiveJudgePort` with that client
/// bound.
struct PoolJudgePort: JudgePort {
    let client: any JudgeClient

    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        JudgeRuntime.runPool(call, client: client)
    }
}

/// The hook-local evaluator asking the judge pool itself (Phase 2b).
@Suite("Hook-local judge")
struct LocalHookJudgeTests {
    /// Pack-allowed, not safe-lane: the judge scores it.
    static let judged = "python3 build.py --release"

    @Test func aJudgedAllowIsFinalAndRvdsReply() async throws {
        let client = ScoredPoolClient(.fixed(choice: "allow"))
        let fixture = try LocalHookFixture(judgeBundle: true, judge: client)
        let stdin = claudeBash(Self.judged, cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        let rvd = try await fixture.rvdReply(host: .claude, stdin: stdin)
        #expect(local == .final(rvd))
        #expect(client.count == 2, "once locally, once by rvd's own runtime in this test")
        let log = try fixture.configFileText("judge-log.jsonl")
        #expect(log.contains(#""choice":"allow""#))
    }

    @Test(arguments: ["review", "block"])
    func aReviewOrBlockVerdictNeverAllowsLocally(_ choice: String) async throws {
        let fixture = try LocalHookFixture(judgeBundle: true, judge: ScoredPoolClient(.fixed(choice: choice)))
        let stdin = claudeBash(Self.judged, cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        switch local {
        case .escalate:
            #expect(fixture.configFileExists("judge-log.jsonl") == false)
        case .final(let reply):
            #expect(reply.stdout.contains(#""permissionDecision":"deny""#), "\(choice) answered \(reply)")
            #expect(reply == (try await fixture.rvdReply(host: .claude, stdin: stdin)))
        }
    }

    /// Shadow (no `judge.mode`, the default) covers the hook-local path:
    /// a review or block from the pool never blocks or asks, it is logged
    /// as a would-be and the call is allowed, exactly as rvd answers it.
    @Test(arguments: ["review", "block"])
    func shadowNeverBlocksOrAsksLocally(_ choice: String) async throws {
        let fixture = try LocalHookFixture(
            judgeBundle: true, judge: ScoredPoolClient(.fixed(choice: choice)), judgeMode: nil)
        let stdin = claudeBash(Self.judged, cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        let rvd = try await fixture.rvdReply(host: .claude, stdin: stdin)
        #expect(!rvd.stdout.contains(#""permissionDecision":"deny""#), "rvd: \(rvd)")
        #expect(!rvd.stdout.contains(#""permissionDecision":"ask""#), "rvd: \(rvd)")
        switch local {
        case .escalate(let reason):
            Issue.record("a shadow verdict is final locally, escalated \(reason)")
        case .final(let reply):
            #expect(!reply.stdout.contains(#""permissionDecision":"deny""#), "\(choice) answered \(reply)")
            #expect(!reply.stdout.contains(#""permissionDecision":"ask""#), "\(choice) answered \(reply)")
            #expect(reply == rvd)
        }
        let log = try fixture.configFileText("judge-log.jsonl")
        #expect(log.contains(#""choice":"\#(choice)""#), "\(log)")
        #expect(log.contains("wouldBe"), "\(log)")
    }

    /// An unknown `judge.mode` is shadow too, on the hook-local path.
    @Test func unknownJudgeModeIsShadowLocally() async throws {
        let fixture = try LocalHookFixture(
            judgeBundle: true, judge: ScoredPoolClient(.fixed(choice: "block")), judgeMode: "bogus")
        let local = await fixture.decider.decide(host: .claude, stdin: claudeBash(Self.judged, cwd: fixture.workspace))
        guard case .final(let reply) = local else {
            Issue.record("a shadow verdict is final locally, got \(local)")
            return
        }
        #expect(!reply.stdout.contains(#""permissionDecision":"deny""#))
        #expect(!reply.stdout.contains(#""permissionDecision":"ask""#))
    }

    static let nonVerdicts: [PoolOutcome?] = [
        nil, .busy, .late, .warming, .failed("worker crashed"),
        .loadFailed(LoadFailure(kind: .badBundle, message: "x")),
        .verdict(Data("{}".utf8), slot: .primary),
        .verdict(Data(#"{"choice":"allow","probabilities":{"allow":1},"riskScore":0,"malicious":0,"risk":0,"checkpoint":"x","latencyMilliseconds":1}"#.utf8), slot: .hedge),
    ]

    @Test(arguments: nonVerdicts)
    func everyPoolNonVerdictEscalatesToTheJudge(_ outcome: PoolOutcome?) async throws {
        let fixture = try LocalHookFixture(judgeBundle: true, judge: ScoredPoolClient(.outcome(outcome)))
        let local = await fixture.decider.decide(host: .claude, stdin: claudeBash(Self.judged, cwd: fixture.workspace))
        #expect(local == .escalate(.judge))
        #expect(fixture.configFileExists("judge-log.jsonl") == false)
    }

    /// The hook-local evaluator selects bundles as rvd does: a bundle dir
    /// that is there but broken (empty here) is selected, so the call asks
    /// the pool, whose load refusal escalates; rvd then refuses (review).
    /// Only an absent bundle dir takes the packs-only floor locally.
    @Test func aBrokenBundleDirEscalatesAndOnlyAnAbsentOneIsPacksOnly() async throws {
        let refused = ScoredPoolClient(.outcome(.loadFailed(LoadFailure(kind: .badBundle, message: "tokenizer.json missing"))))
        let fixture = try LocalHookFixture(judge: refused)
        let stdin = claudeBash(Self.judged, cwd: fixture.workspace)
        guard case .final(let packsOnly) = await fixture.decider.decide(host: .claude, stdin: stdin) else {
            Issue.record("no bundle dir at all is the packs-only floor, final locally")
            return
        }
        #expect(refused.count == 0, "an absent bundle is never judged")

        let bundle = RVPolicyPaths.configDirectory(home: fixture.home)
            .appendingPathComponent("models/\(JudgeRuntime.ftBundleName)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        #expect(local == .escalate(.judge))
        #expect(refused.count == 1, "the broken bundle is selected and the pool asked")
        let rvd = try await fixture.rvdReply(host: .claude, stdin: stdin)
        #expect(rvd != packsOnly, "rvd must not give the packs-only answer for a broken bundle")
        #expect(rvd.stdout.contains("Ask the owner to run `rv doctor`"), "\(rvd.stdout)")
    }

    @Test func withoutAPoolClientAJudgedCallEscalates() async throws {
        let fixture = try LocalHookFixture(judgeBundle: true)
        let local = await fixture.decider.decide(host: .claude, stdin: claudeBash(Self.judged, cwd: fixture.workspace))
        #expect(local == .escalate(.judge))
    }

    // The three tests below pin the C hook's real deadline; the fixture's
    // default is `testLocalDeadline`.

    @Test func theBudgetEndsBeforeTheWritesAndNeverPastThePools() async throws {
        let client = ScoredPoolClient(.fixed(choice: "allow"))
        let fixture = try LocalHookFixture(
            judgeBundle: true, judge: client, localDeadline: LocalHookDecider.localDeadline)
        let started = ContinuousClock.now
        _ = await fixture.decider.decide(
            host: .claude, stdin: claudeBash(Self.judged, cwd: fixture.workspace), started: started)
        // The client may take budget + transport slack: it must be back by
        // the judge deadline, which leaves the reserve for the writes.
        let latest = LocalHookDecider.writeDeadline(started: started) - LocalHookDecider.judgeWriteReserve
            - JudgePoolWire.transportSlack - started
        #expect(LocalHookDecider.judgeBudget(started: started, now: started) == latest)
        // A starved test pool can use up the time before the ask; then the
        // pool is never asked.
        guard let budget = client.budgets.first else { return }
        #expect(budget <= latest)
        #expect(budget <= PoolPolicy.live.budget)
    }

    @Test func tooLittleTimeLeftEscalatesWithoutAsking() async throws {
        let client = ScoredPoolClient(.fixed(choice: "allow"))
        let fixture = try LocalHookFixture(
            judgeBundle: true, judge: client, localDeadline: LocalHookDecider.localDeadline)
        let local = await fixture.decider.decide(
            host: .claude, stdin: claudeBash(Self.judged, cwd: fixture.workspace),
            started: .now - .milliseconds(600))
        #expect(local == .escalate(.judge))
        #expect(client.count == 0)
    }

    /// A silent pool holds the call for its whole budget plus the transport
    /// slack. The budget is cut at the moment of asking so that worst case
    /// still ends `judgeWriteReserve` before the write deadline, and the
    /// call escalates. Checked against the instants the client saw, not the
    /// wall clock, which a starved test pool stretches without bound.
    @Test func aPoolThatNeverAnswersStillEscalatesBeforeTheWriteDeadline() async throws {
        let client = ScoredPoolClient(.silent)
        let fixture = try LocalHookFixture(
            judgeBundle: true, judge: client, localDeadline: LocalHookDecider.localDeadline)
        let started = ContinuousClock.now
        let local = await fixture.decider.decide(
            host: .claude, stdin: claudeBash(Self.judged, cwd: fixture.workspace), started: started)
        #expect(local == .escalate(.judge))
        // On a starved pool the evaluation can use up the time before the
        // ask: then the pool is never asked, which is just as bounded.
        guard client.count > 0 else { return }
        #expect(client.count == 1)
        let budget = try #require(client.budgets.first)
        let called = try #require(client.instants.first)
        #expect(budget >= LocalHookDecider.minimumJudgeBudget)
        // The instant the budget was cut at: the client back by then plus
        // budget plus slack is back by the judge deadline exactly. It lies
        // between the start and the client's call.
        let asked = LocalHookDecider.writeDeadline(started: started) - LocalHookDecider.judgeWriteReserve
            - JudgePoolWire.transportSlack - budget
        #expect(asked >= started)
        #expect(asked <= called)
    }

    @Test func observeAsksThePoolOnceForBothPasses() async throws {
        let client = ScoredPoolClient(.fixed(choice: "allow"))
        let fixture = try LocalHookFixture(judgeBundle: true, guardMode: "observe", judge: client)
        let stdin = claudeBash(Self.judged, cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        #expect(client.count == 1)
        #expect(local == .final(try await fixture.rvdReply(host: .claude, stdin: stdin)))
    }

    @Test func observeWithAReviewVerdictEscalates() async throws {
        let fixture = try LocalHookFixture(
            judgeBundle: true, guardMode: "observe", judge: ScoredPoolClient(.fixed(choice: "review")))
        let local = await fixture.decider.decide(host: .claude, stdin: claudeBash(Self.judged, cwd: fixture.workspace))
        // The would-be deny reaches the Policy gate (or differs from the
        // enforce pass): rvd answers it either way.
        guard case .escalate = local else {
            Issue.record("an observed review must go to rvd, got \(local)")
            return
        }
    }
}

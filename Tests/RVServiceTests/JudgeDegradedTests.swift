import Foundation
import Synchronization
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// Fixed judge reading that counts its calls.
private final class CountingJudge: JudgePort, Sendable {
    let run: JudgeRuntime.JudgeRun
    private let calls = Mutex(0)
    init(_ run: JudgeRuntime.JudgeRun) { self.run = run }
    var count: Int { calls.withLock { $0 } }
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        calls.withLock { $0 += 1 }
        return run
    }
}

/// Hands the late-result callback back to the test, then answers `late`.
private final class LateJudge: JudgePort, Sendable {
    private let sink = Mutex<(@Sendable (JudgeRuntime.JudgeRun, Duration) -> Void)?>(nil)
    var onLate: (@Sendable (JudgeRuntime.JudgeRun, Duration) -> Void)? { sink.withLock { $0 } }
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        sink.withLock { $0 = call.onLateResult }
        return .late
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let fakeBundle = JudgeSelection(
    engine: .ft, bundle: URL(fileURLWithPath: "/nonexistent/rv-fake-bundle", isDirectory: true), shadow: false
)
/// Pack-allowed and outside the safe lane, so it reaches the judge.
private let judged = ShellCommand(rawValue: "python3 deploy.py --prod")

private func inputs(_ mode: GuardMode, home: HomeDirectory?) -> EvaluationInputs {
    EvaluationInputs(guardMode: mode, judge: fakeBundle, store: .gather(home: home, cwd: nil))
}

private func request(_ command: ShellCommand) -> EvaluationRequest {
    EvaluationRequest(command: command, enabledPacks: dayOnePackIDs, provenance: .unknown)
}

/// The judge's degraded states keep rv's posture: enforce sends what the
/// judge would have scored to review, observe logs a would-be review and
/// allows, and a not-allow never turns into an allow.
@Suite("Judge degraded: late and circuit-open")
struct JudgeDegradedTests {
    @Test("enforce: an open circuit sends the judged call to review, labeled degraded")
    func enforceReviewsWhenCircuitOpen() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let result = GatedEvaluate(EvaluateSession(), judge: CountingJudge(.circuitOpen(retryIn: .seconds(42))))
            .evaluateAgent(request(judged), cwd: nil, home: home, now: now, inputs: inputs(.enforce, home: home))
        guard case .deny(let deny) = result.decision else {
            Issue.record("an open circuit must not allow, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreJudge, pattern: "laya-review"))
        #expect(deny.reason.contains("rv degraded: judge unavailable (circuit open, retrying in 42s)"))
        #expect(HookAuthorization.isPinned(result) == false)
        let row = try #require(try judgeLog(home).last)
        #expect(row["live"] as? String == "deny")
        #expect(row["note"] as? String == "judge-circuit-open; context: partial")
    }

    @Test("enforce: a late judge sends the judged call to review, labeled late")
    func enforceReviewsWhenLate() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let result = GatedEvaluate(EvaluateSession(), judge: CountingJudge(.late))
            .evaluateAgent(request(judged), cwd: nil, home: home, now: now, inputs: inputs(.enforce, home: home))
        guard case .deny(let deny) = result.decision else {
            Issue.record("a late judge must not allow, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreJudge, pattern: "laya-review"))
        #expect(deny.reason.contains("rv degraded: judge late"))
        let row = try #require(try judgeLog(home).last)
        #expect(row["note"] as? String == "judge-late; context: partial")
    }

    @Test(
        "observe: late and circuit-open behave like busy (would-be review, live allow)",
        arguments: [JudgeRuntime.JudgeRun.busy, .late, .circuitOpen(retryIn: .seconds(5))]
    )
    func observeMatchesBusy(run: JudgeRuntime.JudgeRun) throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let result = GatedEvaluate(EvaluateSession(), judge: CountingJudge(run))
            .evaluateAgent(request(judged), cwd: nil, home: home, now: now, inputs: inputs(.observe, home: home))
        #expect(result.decision == .allow)
        let row = try #require(try judgeLog(home).last)
        #expect(row["guard"] as? String == "observe")
        #expect(row["wouldBe"] as? String == "deny")
        #expect(row["wouldBeRule"] as? String == "core.judge:laya-review")
    }

    @Test("rules-decided calls never reach the judge", arguments: [GuardMode.enforce, .observe])
    func rulesDecidedBypassTheJudge(mode: GuardMode) throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let judge = CountingJudge(.late)
        let door = GatedEvaluate(EvaluateSession(), judge: judge)
        // A pack deny: decided by the rules (not `rm -rf ~`, which observe floors).
        let denied = door.evaluateAgent(
            request(ShellCommand(rawValue: "rm -rf ~/Documents")), cwd: nil, home: home, now: now,
            inputs: inputs(mode, home: home))
        if mode == .enforce {
            guard case .deny = denied.decision else {
                Issue.record("a pack deny must stay a deny, got \(denied.decision)")
                return
            }
        }
        // A safe-lane allow.
        let safe = door.evaluateAgent(
            request(ShellCommand(rawValue: "ls -la")), cwd: nil, home: home, now: now,
            inputs: inputs(mode, home: home))
        #expect(safe.decision == .allow)
        #expect(judge.count == 0)
    }

    @Test("a late prediction is logged with its real ms; the returned verdict stands")
    func lateResultIsLogged() throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let judge = LateJudge()
        let result = GatedEvaluate(EvaluateSession(), judge: judge)
            .evaluateAgent(request(judged), cwd: nil, home: home, now: now, inputs: inputs(.enforce, home: home))
        guard case .deny = result.decision else {
            Issue.record("late must review, got \(result.decision)")
            return
        }
        let onLate = try #require(judge.onLate, "the door must hand the judge a late-result logger")
        onLate(.verdict(try lateVerdict(ms: 145_000)), .seconds(145))
        let rows = try judgeLog(home)
        #expect(rows.count == 2)
        // The request's own row is not marked; the late answer is.
        #expect(rows.first?["lateOf"] == nil)
        let late = try #require(rows.last)
        #expect(late["lateOf"] as? Bool == true)
        #expect(late["note"] as? String == "late-result; context: partial")
        #expect(late["ms"] as? Double == 145_000)
        #expect(late["live"] as? String == "deny")
        // A late run without a verdict names the outcome and run time.
        onLate(.failed, .milliseconds(9_500))
        let failed = try #require(try judgeLog(home).last)
        #expect(failed["note"] as? String == "late-result: prediction-failed after 9500 ms; context: partial")
        #expect(failed["lateOf"] as? Bool == true)
    }
}

/// A judge verdict through its public Codable surface; the type is inferred
/// from the `.verdict` payload, so this target never names it.
private func lateVerdict<T: Decodable>(ms: Double) throws -> T {
    let json = """
    {"choice":"allow","probabilities":{},"riskScore":0.1,"malicious":0,
     "risk":0.1,"checkpoint":"fake","latencyMilliseconds":\(ms),"truncated":false}
    """
    return try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

#if canImport(CoreML)
@Suite("Doctor shows the judge circuit")
struct JudgeCircuitDoctorTests {
    private func homeWithBundle(mode: String? = nil) throws -> HomeDirectory {
        let home = try guardHome(mode: mode)
        let bundle = RVPolicyPaths.configDirectory(home: home)
            .appendingPathComponent("models/\(JudgeRuntime.ftBundleName)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer.json"))
        return home
    }

    @Test func closedIsOkOpenAndHalfOpenWarn() throws {
        let home = try homeWithBundle()
        defer { remove(home) }
        let closed = DoctorSnapshotBuilder.judgeCheck(home: home, circuit: .closed)
        #expect(closed.status == .ok)
        #expect(closed.message.contains("degraded") == false)

        let open = DoctorSnapshotBuilder.judgeCheck(home: home, circuit: .open(retryIn: .milliseconds(41_200)))
        #expect(open.status == .warning)
        #expect(open.message.contains("rv degraded: judge unavailable (circuit open, retrying in 42s)"))
        #expect(open.message.contains("judged calls go to review"))

        let next = DoctorSnapshotBuilder.judgeCheck(home: home, circuit: .halfOpen(trialInFlight: false))
        #expect(next.status == .warning)
        #expect(next.message.contains("half-open, the next judged call is a trial"))

        let running = DoctorSnapshotBuilder.judgeCheck(home: home, circuit: .halfOpen(trialInFlight: true))
        #expect(running.status == .warning)
        #expect(running.message.contains("half-open, a trial call is running"))
    }

    @Test func observeSaysWouldBeReviewNotReview() throws {
        let home = try homeWithBundle(mode: "observe")
        defer { remove(home) }
        let open = DoctorSnapshotBuilder.judgeCheck(home: home, circuit: .open(retryIn: .seconds(10)))
        #expect(open.message.contains("logged as a would-be review"))
        #expect(open.message.contains("go to review") == false)
    }
}
#endif

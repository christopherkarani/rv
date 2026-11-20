import Dispatch
import Foundation
import Synchronization
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// A judge whose prediction goes through a real admission (bounded by the
/// judge deadline the offload binds) and never answers until released. A
/// watchdog releases it after 30 s, so a missing bound fails the test
/// (`releasedByWatchdog`) instead of hanging it.
private final class StuckJudge: JudgePort, Sendable {
    private let admission = JudgeAdmission(limit: 4)
    private let release = DispatchSemaphore(value: 0)
    private let delivered = DispatchSemaphore(value: 0)
    private let state = Mutex((released: false, byWatchdog: false, late: false))

    init() {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(30)) { [weak self] in
            self?.free(byWatchdog: true)
        }
    }

    var releasedByWatchdog: Bool { state.withLock { $0.byWatchdog } }

    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        let release = self.release
        let logger = call.onLateResult ?? { _, _ in }
        let run = JudgeRuntime.admitted(
            through: admission,
            onLate: { [delivered] run, ran in
                logger(run, ran)
                delivered.signal()
            }
        ) {
            release.wait()
            return .failed
        }
        if case .late = run { state.withLock { $0.late = true } }
        return run
    }

    /// Releases the prediction and, when it went late, waits for its late
    /// row so nothing writes into a home the test is about to remove.
    func finish() {
        free(byWatchdog: false)
        if state.withLock({ $0.late }) {
            _ = delivered.wait(timeout: .now() + 10)
        }
    }

    private func free(byWatchdog: Bool) {
        let first = state.withLock { state in
            guard state.released == false else { return false }
            state.released = true
            state.byWatchdog = byWatchdog
            return true
        }
        if first { release.signal() }
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
/// Pack-allowed and outside the safe lane, so it reaches the judge.
private let judged = ShellCommand(rawValue: "python3 deploy.py --prod")

/// A guard home with an installed (fake) judge bundle, so the door
/// consults the judge port.
private func homeWithBundle() throws -> HomeDirectory {
    let home = try guardHome(mode: nil)
    let bundle = RVPolicyPaths.configDirectory(home: home)
        .appendingPathComponent("models/\(JudgeRuntime.ftBundleName)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: bundle.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer.json"))
    return home
}

private func expectLateReview(_ result: EvaluationResult, home: HomeDirectory, judge: StuckJudge) throws {
    #expect(judge.releasedByWatchdog == false, "the judge wait was not bounded")
    guard case .deny(let deny) = result.decision else {
        Issue.record("a late judge must go to review, got \(result.decision)")
        return
    }
    #expect(deny.ruleID == RuleID(pack: .coreJudge, pattern: "laya-review"))
    #expect(deny.reason.contains("rv degraded: judge late"))
    let row = try #require(try judgeLog(home).first)
    #expect(row["note"] as? String == "judge-late; context: partial")
}

/// rvd's doors without a hook deadline (SDK evaluate, explain, classify,
/// the agent bridge, approval-path peeks) bound the judge, and only the
/// judge: the rule verdict never turns indeterminate because of it, and a
/// stuck prediction answers review within the bound.
@Suite("Judge bound on non-hook doors")
struct JudgeNonHookBoundTests {
    /// The judge budget already spent when the evaluation starts: pattern
    /// search keeps its own ceiling, so the rule's deny stands.
    @Test func aSpentJudgeBudgetLeavesTheRuleDeny() async throws {
        let home = try homeWithBundle()
        let judge = StuckJudge()
        defer {
            judge.finish()
            remove(home)
        }
        let door = GatedEvaluate(EvaluateSession(), judge: judge)
        let result = await JudgeOffload.$judgeBudget.withValue(.zero) {
            await door.apply(
                command: ShellCommand(rawValue: "git reset --hard"), cwd: wd("/tmp/ws"), home: home,
                grants: EphemeralAllowOnceTable(), now: now, allowlist: { .empty })
        }
        guard case .deny(let deny) = result.decision else {
            Issue.record("a spent judge budget must leave the reset-hard deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    /// A stuck prediction on an evaluate door answers review (judge-late)
    /// at its judge bound, as on the hook door.
    @Test func aStuckJudgeOnAnEvaluateDoorReviewsInsideItsBound() async throws {
        let home = try homeWithBundle()
        let judge = StuckJudge()
        defer {
            judge.finish()
            remove(home)
        }
        let door = GatedEvaluate(EvaluateSession(), judge: judge)
        let result = await JudgeOffload.$judgeBudget.withValue(.seconds(2)) {
            await door.apply(
                command: judged, cwd: wd("/tmp/ws"), home: home,
                grants: EphemeralAllowOnceTable(), now: now, allowlist: { .empty })
        }
        try expectLateReview(result, home: home, judge: judge)
    }
}

import Dispatch
import Foundation
import Synchronization
import Testing
import RVDomain
import RVHooks
import RVIPC
import RVPolicy
@testable import RVService

/// The hook deadline's own clock, moved by the test: the door's side-effect
/// checks read it, so how much budget is left when the late judge hands
/// back is set by the test, not by how starved the runner is.
private final class DeadlineClock: Sendable {
    private let instant: Mutex<ContinuousClock.Instant>
    init(_ start: ContinuousClock.Instant) { instant = Mutex(start) }
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func set(_ value: ContinuousClock.Instant) { instant.withLock { $0 = value } }
}

/// A judge whose prediction goes through a real admission and never answers
/// until released: the stuck Core ML prediction of Nov 19. It records the
/// deadline the door handed it, then waits only `window` of real time from
/// its own start (so a starved runner cannot spend its wait before it runs).
/// When it goes late it moves the deadline clock to `handBack`.
private final class StuckJudge: JudgePort, Sendable {
    static let window: Duration = JudgeAdmission.replyMargin + .milliseconds(500)
    private let admission = JudgeAdmission(limit: 4)
    private let release = DispatchSemaphore(value: 0)
    private let delivered = DispatchSemaphore(value: 0)
    private let clock: DeadlineClock
    private let handBack: ContinuousClock.Instant
    private let state = Mutex((seen: ContinuousClock.Instant?.none, late: false, released: false))

    init(clock: DeadlineClock, handBack: ContinuousClock.Instant) {
        self.clock = clock
        self.handBack = handBack
    }

    var seenDeadline: ContinuousClock.Instant? { state.withLock { $0.seen } }

    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        state.withLock { $0.seen = JudgeAdmission.deadline }
        let release = self.release
        let logger = call.onLateResult ?? { _, _ in }
        let run = JudgeRuntime.admitted(
            through: admission,
            until: ContinuousClock.now.advanced(by: Self.window),
            onLate: { [delivered] run, ran in
                logger(run, ran)
                delivered.signal()
            }
        ) {
            release.wait()
            return .failed
        }
        if case .late = run {
            state.withLock { $0.late = true }
            clock.set(handBack)
        }
        return run
    }

    /// Releases the prediction and waits for its late row, so the logger
    /// never writes into a home the test has removed.
    func finish() {
        let (late, first) = state.withLock { state in
            defer { state.released = true }
            return (state.late, state.released == false)
        }
        guard first else { return }
        release.signal()
        if late { _ = delivered.wait(timeout: .now() + 10) }
    }
}

/// Through `HookDoor.run` with a real `HookDeadline`: a judge that does not
/// answer must leave room for the review reply, its pending row and its
/// unlock code before the deadline swaps in the timeout deny, and the door
/// must honour that deadline when the room is gone.
///
/// Deterministic: the deadline's clock is virtual (`DeadlineClock`), and its
/// `expiresAt` is far off in real time, so no real-time check (pattern
/// search, the judge's slot wait) can trip on a starved runner.
@Suite("Late judge through the hook door")
struct JudgeLateHookDoorTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","sessionId":"sess-pi","input":{"command":"python3 deploy.py --prod"}}
    """

    private struct Rig {
        let homeURL: URL
        let allowOnceDirectory: URL
        let pending: PendingApprovalStore
        let world: HookEvaluateWorld
        let deadline: HookDeadline
        let judge: StuckJudge

        func remove() {
            judge.finish()
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
    }

    /// `handBack(expiresAt)`: the deadline clock once the judge is late.
    private static func rig(
        handBack: (ContinuousClock.Instant) -> ContinuousClock.Instant
    ) throws -> Rig {
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        // An installed bundle, so the door consults the (fake) judge.
        let bundle = RVPolicyPaths.configDirectory(home: home)
            .appendingPathComponent("models/\(JudgeRuntime.ftBundleName)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer.json"))

        let received = ContinuousClock.now
        let expiresAt = received.advanced(by: .seconds(3600))
        let clock = DeadlineClock(received)
        let judge = StuckJudge(clock: clock, handBack: handBack(expiresAt))
        let live = LiveEvaluateWorld(
            home: home,
            store: AllowOnceStore(baseDirectory: allowOnceDirectory),
            grants: EphemeralAllowOnceTable(),
            gated: GatedEvaluate(EvaluateSession(), judge: judge),
            clock: { Self.now },
            allowlist: { _, _ in .empty }
        )
        let pending = PendingApprovalStore.makeLive(home: home)
        return Rig(
            homeURL: homeURL,
            allowOnceDirectory: allowOnceDirectory,
            pending: pending,
            world: HookEvaluateWorld.live(world: live, host: .pi, pending: pending, clock: { Self.now }),
            deadline: HookDeadline(expiresAt: expiresAt, now: { clock.now }),
            judge: judge
        )
    }

    private static func unlockRows(_ rig: Rig) -> String {
        (try? String(
            contentsOf: rig.allowOnceDirectory.appendingPathComponent("allow-once.jsonl"), encoding: .utf8)) ?? ""
    }

    /// The judge goes late at the cutoff `JudgeAdmission` keeps for it
    /// (`expiresAt - replyMargin`): review, pending row and unlock code all
    /// land, and the judge-late row is logged.
    @Test func aStuckPredictionRepliesReviewWithAPendingRowInsideTheBudget() async throws {
        let rig = try Self.rig(handBack: { $0 - JudgeAdmission.replyMargin })
        defer { rig.remove() }

        let reply = try await HookDoor.run(host: .pi, stdin: Self.stdin, world: rig.world, deadline: rig.deadline)

        // The door handed the judge this request's hook deadline.
        #expect(rig.judge.seenDeadline == rig.deadline.expiresAt)
        // A review, not the timeout deny: every side effect landed in time.
        #expect(rig.deadline.requiresTimeoutReply == false)
        #expect(reply.stdout.contains("timed out") == false)
        #expect(try await rig.pending.list(now: Self.now).count == 1)
        #expect(Self.unlockRows(rig).isEmpty == false)
        let home = try #require(HomeDirectory(validating: rig.homeURL.path))
        let row = try #require(try judgeLog(home).first)
        #expect(row["note"] as? String == "judge-late; context: partial")
        #expect(row["live"] as? String == "deny")
    }

    /// The converse: a late judge that hands back with the budget spent
    /// gets the timeout deny, and claims no pending row or unlock code.
    @Test func aLateJudgePastTheDeadlineGetsTheTimeoutReply() async throws {
        let rig = try Self.rig(handBack: { $0 })
        defer { rig.remove() }

        let reply = try await HookDoor.run(host: .pi, stdin: Self.stdin, world: rig.world, deadline: rig.deadline)

        #expect(rig.judge.seenDeadline == rig.deadline.expiresAt)
        #expect(rig.deadline.requiresTimeoutReply)
        #expect(reply.stdout.contains("timed out"))
        #expect(try await rig.pending.list(now: Self.now).isEmpty)
        #expect(Self.unlockRows(rig).isEmpty)
    }
}

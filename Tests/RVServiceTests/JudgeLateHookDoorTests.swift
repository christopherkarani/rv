import Dispatch
import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
import RVPolicy
@testable import RVService

/// A judge whose prediction goes through a real admission and never answers
/// until released: the stuck Core ML prediction of Nov 19.
private final class StuckJudge: JudgePort, Sendable {
    let admission = JudgeAdmission(limit: 4)
    let release = DispatchSemaphore(value: 0)

    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        let release = self.release
        return JudgeRuntime.admitted(through: admission, onLate: call.onLateResult ?? { _, _ in }) {
            release.wait()
            return .failed
        }
    }
}

/// Through `HookDoor.run` with the real hook budget: a judge that does not
/// answer must still leave room for the review reply, its pending row and
/// its unlock code before the deadline swaps in the timeout deny.
@Suite("Late judge through the hook door")
struct JudgeLateHookDoorTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","sessionId":"sess-pi","input":{"command":"python3 deploy.py --prod"}}
    """

    @Test func aStuckPredictionRepliesReviewWithAPendingRowInsideTheBudget() async throws {
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        // An installed bundle, so the door consults the (fake) judge.
        let bundle = RVPolicyPaths.configDirectory(home: home)
            .appendingPathComponent("models/\(JudgeRuntime.ftBundleName)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("model.mlpackage"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer.json"))

        let judge = StuckJudge()
        defer { judge.release.signal() }
        let live = LiveEvaluateWorld(
            home: home,
            store: AllowOnceStore(baseDirectory: allowOnceDirectory),
            grants: EphemeralAllowOnceTable(),
            gated: GatedEvaluate(EvaluateSession(), judge: judge),
            clock: { Self.now },
            allowlist: { _, _ in .empty }
        )
        let pending = PendingApprovalStore.makeLive(home: home)
        let world = HookEvaluateWorld.live(world: live, host: .pi, pending: pending, clock: { Self.now })
        let deadline = HookDeadline()

        let reply = try await HookDoor.run(host: .pi, stdin: Self.stdin, world: world, deadline: deadline)

        // A review, not the timeout deny: every side effect landed in time.
        #expect(deadline.requiresTimeoutReply == false)
        #expect(reply.stdout.contains("timed out") == false)
        #expect(try await pending.list(now: Self.now).count == 1)
        let unlockRows = (try? String(
            contentsOf: allowOnceDirectory.appendingPathComponent("allow-once.jsonl"), encoding: .utf8)) ?? ""
        #expect(unlockRows.isEmpty == false)
        let row = try #require(try judgeLog(home).first)
        #expect(row["note"] as? String == "judge-late; context: partial")
        #expect(row["live"] as? String == "deny")
    }
}

import Foundation
import Testing
import RVDomain
import RVHooks
@testable import RVService
import Synchronization

/// A hook that runs past its deadline leaves one `rvd.log` line with
/// per-phase durations and the rule, never the command.
@Suite struct HookTimingTests {
    private static let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","sessionId":"sess-pi","input":{"command":"git reset --hard"}}
    """

    private final class Lines: Sendable {
        let written = Mutex<[String]>([])
        var all: [String] { written.withLock { $0 } }
        func log() -> SlowHookLog { SlowHookLog(write: { line in self.written.withLock { $0.append(line) } }) }
    }

    @Test func inTimeRequestsLogNothing() {
        let timing = HookTiming()
        timing.add(.policy, .milliseconds(3))
        #expect(timing.slowMessage(host: "claude", total: .milliseconds(40), budget: .seconds(7), tripped: false) == nil)
    }

    @Test func lateRequestLineCarriesPhasesAndRuleOnly() throws {
        let timing = HookTiming()
        timing.add(.queue, .milliseconds(2))
        timing.add(.judgeAdmission, .milliseconds(6_100))
        timing.add(.judgePredict, .milliseconds(1_180))
        timing.add(.judgePredict, .milliseconds(20))
        timing.settle(door: "shell", rule: "core.git:reset-hard")
        let message = try #require(timing.slowMessage(
            host: "claude", total: .milliseconds(7_412), budget: .seconds(7), tripped: true))
        #expect(message == "rvd: hook ran past its deadline: host=claude door=shell total_ms=7412 budget_ms=7000 "
            + "tripped=true queue_ms=2 judge_admission_ms=6100 judge_predict_ms=1200 rule=core.git:reset-hard")
        // Over budget without a tripped check (an allow with nothing to skip) still logs.
        #expect(timing.slowMessage(host: "claude", total: .seconds(8), budget: .seconds(7), tripped: false) != nil)
    }

    @Test func slowLogWritesAtMostOneLinePerIntervalAndCountsTheRest() {
        let lines = Lines()
        let log = lines.log()
        let start = ContinuousClock.now
        #expect(log.report("first", now: start))
        #expect(log.report("second", now: start + .milliseconds(200)) == false)
        #expect(log.report("third", now: start + .milliseconds(400)) == false)
        #expect(log.report("fourth", now: start + SlowHookLog.interval))
        #expect(lines.all.count == 2)
        #expect(lines.all[0].hasSuffix(" first\n"))
        #expect(lines.all[1].hasSuffix(" fourth skipped_since_last=2\n"))
    }

    @Test func offloadedPhasesReachTheRequestTiming() async {
        let timing = HookTiming()
        await HookTiming.$current.withValue(timing) {
            await JudgeOffload.run { HookTiming.measure(.policy) { usleep(2_000) } }
        }
        #expect(timing.durations[.offloadWait] != nil)
        #expect((timing.durations[.policy] ?? .zero) >= .milliseconds(2))
        // Unbound: measuring is a plain call.
        #expect(HookTiming.measure(.policy) { 7 } == 7)
    }

    @Test func hookDoorLogsTheLateRequestWithoutItsCommand() async throws {
        let lines = Lines()
        let deadline = HookDeadline(receivedAt: .now, budget: .milliseconds(100))
        let world = hookWorld(evaluate: { _, _ in
            try? await Task.sleep(for: .milliseconds(250))
            return EvaluationResult(outcome: .plain)
        })
        _ = try await HookDoor.run(host: .pi, stdin: Self.stdin, world: world, deadline: deadline, slowLog: lines.log())
        let line = try #require(lines.all.first)
        #expect(lines.all.count == 1)
        #expect(line.contains("rvd: hook ran past its deadline: host=pi "))
        #expect(line.contains(" queue_ms="))
        #expect(line.contains(" reply_ms="))
        #expect(line.contains("reset") == false, "no command text")

        let inTime = Lines()
        _ = try await HookDoor.run(
            host: .pi, stdin: Self.stdin, world: hookWorld(evaluate: { _, _ in EvaluationResult(outcome: .plain) }),
            deadline: HookDeadline(), slowLog: inTime.log())
        #expect(inTime.all.isEmpty)
    }

    @Test func requestQueuedPastItsDeadlineIsLoggedToo() async throws {
        let lines = Lines()
        let start = ContinuousClock.now - .seconds(9)
        let stale = HookDeadline(expiresAt: start + .seconds(7), receivedAt: start, now: { .now })
        _ = try await HookDoor.run(
            host: .claude, stdin: "{}", world: hookWorld(evaluate: { _, _ in
                Issue.record("a request past its deadline is not evaluated")
                return EvaluationResult(outcome: .plain)
            }),
            deadline: stale, slowLog: lines.log())
        let line = try #require(lines.all.first)
        #expect(line.contains("host=claude door=none"))
        #expect(line.contains("tripped=true"))
        #expect(line.contains(" queue_ms=9"))
    }
}

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

    @Test func slowLogWritesAtMostOneLinePerMinuteAndCountsTheRest() {
        #expect(SlowHookLog.interval == .seconds(60), "rvd.log rotates only at start; AuditDropLog's rate")
        let lines = Lines()
        let log = lines.log()
        let start = ContinuousClock.now
        #expect(log.report("first", now: start))
        #expect(log.report("second", now: start + .seconds(1)) == false)
        #expect(log.report("third", now: start + .seconds(59)) == false)
        #expect(log.report("fourth", now: start + SlowHookLog.interval))
        #expect(log.report("fifth", now: start + SlowHookLog.interval + .seconds(1)) == false)
        #expect(log.report("sixth", now: start + SlowHookLog.interval * 2))
        #expect(lines.all.count == 3)
        #expect(lines.all[0].hasSuffix(" first\n"))
        #expect(lines.all[1].hasSuffix(" fourth skipped_since_last=2\n"))
        #expect(lines.all[2].hasSuffix(" sixth skipped_since_last=1\n"), "the skipped count reaches the next line")
    }

    /// A request stuck past its deadline may never reach the completion
    /// line; the watchdog logs what it measured so far, once, and the
    /// completion line still follows when it does finish.
    /// No wall clock: the watchdog wakes at once, and the request stays
    /// stuck until the watchdog has written its line.
    @Test func stuckRequestIsLoggedByTheWatchdogOnce() async throws {
        let lines = Lines()
        let (written, signal) = AsyncStream<Void>.makeStream()
        let log = SlowHookLog(write: { line in
            lines.written.withLock { $0.append(line) }
            signal.yield()
        })
        // Received a second ago, due half a second ago: past its budget,
        // yet its own clock still permits side effects, so it runs.
        let start = ContinuousClock.now
        let deadline = HookDeadline(
            expiresAt: start - .milliseconds(500), receivedAt: start - .seconds(1), now: { start - .seconds(1) })
        let world = hookWorld(evaluate: { _, _ in
            for await _ in written { break }
            return EvaluationResult(outcome: .plain)
        })
        _ = try await HookDoor.run(
            host: .pi, stdin: Self.stdin, world: world, deadline: deadline, slowLog: log,
            hungGrace: .zero, watchdogSleep: { _ in })
        let line = try #require(lines.all.first)
        #expect(lines.all.count == 2, "watchdog lines have their own window")
        #expect(lines.all.last?.contains("rvd: hook ran past its deadline: host=pi ") == true)
        #expect(line.contains("rvd: hook still running past its deadline: host=pi "))
        #expect(line.contains(" queue_ms="))
        #expect(line.contains("reset") == false, "no command text")
    }

    /// A request that finishes in time cancels its watchdog: no stale
    /// "still running" line once the grace has passed.
    @Test func fastRequestLeavesNoWatchdogLine() async throws {
        let lines = Lines()
        let deadline = HookDeadline(receivedAt: .now, budget: .milliseconds(20))
        _ = try await HookDoor.run(
            host: .pi, stdin: Self.stdin, world: hookWorld(evaluate: { _, _ in EvaluationResult(outcome: .plain) }),
            deadline: deadline, slowLog: lines.log(), hungGrace: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(200))
        #expect(lines.all.isEmpty)
    }

    /// The watchdog's sleep ends just as the request finishes, so it
    /// returns instead of throwing: the cancellation check after the sleep
    /// keeps a finished request from logging as still running.
    @Test func watchdogWakingAtCancellationLogsNothing() async throws {
        let lines = Lines()
        let deadline = HookDeadline(receivedAt: .now, budget: .seconds(60))
        _ = try await HookDoor.run(
            host: .pi, stdin: Self.stdin, world: hookWorld(evaluate: { _, _ in EvaluationResult(outcome: .plain) }),
            deadline: deadline, slowLog: lines.log(), hungGrace: .zero,
            watchdogSleep: { _ in
                // Wakes only once cancelled, and without throwing.
                while Task.isCancelled == false { await Task.yield() }
            })
        try await Task.sleep(for: .milliseconds(200))
        #expect(lines.all.isEmpty)
    }

    /// A burst of completion lines never hides a stuck request, and stuck
    /// requests are still limited to one line per interval.
    @Test func watchdogLinesHaveTheirOwnWindow() {
        let lines = Lines()
        let log = lines.log()
        let start = ContinuousClock.now
        #expect(log.report("done", now: start))
        #expect(log.report("stuck", running: true, now: start + .seconds(1)))
        #expect(log.report("stuck again", running: true, now: start + .seconds(2)) == false)
        #expect(log.report("done again", now: start + .seconds(3)) == false)
        #expect(log.report("stuck late", running: true, now: start + .seconds(1) + SlowHookLog.interval))
        #expect(lines.all.count == 3)
        #expect(lines.all[2].hasSuffix(" stuck late skipped_since_last=1\n"))
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

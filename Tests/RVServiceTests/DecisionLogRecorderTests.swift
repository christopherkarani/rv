import Foundation
import RVDomain
import RVHistory
import RVHooks
import RVPolicy
@testable import RVService
import Testing

@Suite("Decision log recorder")
struct DecisionLogRecorderTests {
    static let now = Date(timeIntervalSince1970: 1_795_356_000)
    static let home = HomeDirectory(validating: "/Users/ann")
    static let rule = RuleID(pack: PackID(rawValue: "core.git"), pattern: "force-push")

    static func record(_ result: EvaluationResult, timedOut: Bool = false) -> DecisionRecord {
        DecisionLogRecorder.record(
            result, tool: .bash, command: "git push", path: nil,
            cwd: WorkingDirectory(validating: "/Users/ann/src/rv"), host: .hook(.claude), home: home,
            at: now, timedOut: timedOut, session: "s-1"
        )
    }

    @Test func allowsCarryNoRule() {
        let row = Self.record(EvaluationResult(outcome: .plain))
        #expect(row == DecisionRecord(
            time: Self.now, verdict: .allowed, host: .hook(.claude), tool: .bash, command: "git push",
            cwd: "~/src/rv", session: "s-1"
        ))
    }

    @Test func deniesNameTheirRule() {
        let row = Self.record(EvaluationResult(outcome: .deny(Deny(ruleID: Self.rule, reason: "no"), matched: nil)))
        #expect(row.verdict == .denied)
        #expect(row.rule == "core.git:force-push")
    }

    @Test func indeterminateAndTimeoutAreRefusals() {
        let unfinished = Self.record(EvaluationResult(outcome: .indeterminate(.budgetExhausted)))
        #expect(unfinished.verdict == .refused)
        #expect(unfinished.rule == "rv.indeterminate:budgetExhausted")
        let late = Self.record(EvaluationResult(outcome: .plain), timedOut: true)
        #expect(late.verdict == .refused)
        #expect(late.rule == DecisionLogRecorder.timeoutRule)
    }

    static func capture(_ result: EvaluationResult, _ subject: HookDecisionTap.Capture.Subject) -> HookDecisionTap.Capture {
        HookDecisionTap.Capture(
            result: result, subject: subject, cwd: nil, host: .codex, startedAt: now, session: "abc-123")
    }

    static func written(
        _ capture: HookDecisionTap.Capture, timedOut: Bool, call: DecisionCall? = nil
    ) async throws -> DecisionRecord {
        let (stream, continuation) = AsyncStream.makeStream(of: DecisionRecord.self)
        let recorder = DecisionLogRecorder(home: home) { continuation.yield($0) }
        recorder.record(capture, timedOut: timedOut, call: call)
        var iterator = stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    @Test func theStampGivesTheIDAndAnAllowsWouldBe() async throws {
        let stamp = DecisionCall(stamp: DecisionStamp(id: "a7c835000001"))
        stamp.note(DecisionWouldBe(verdict: .denied, rule: "core.git:force-push", ask: true))
        // rvd: the tapped capture, with the call's stamp.
        let allowed = try await Self.written(
            Self.capture(EvaluationResult(outcome: .plain), .shell(ShellCommand(rawValue: "git push -f"))),
            timedOut: false, call: stamp)
        #expect(allowed.id == "a7c835000001")
        #expect(allowed.wouldBe == DecisionWouldBe(verdict: .denied, rule: "core.git:force-push", ask: true))
        #expect(allowed.code == "a7c-835")
        // Only an allow carries a would-be; a stop is its own verdict.
        let late = try await Self.written(
            Self.capture(EvaluationResult(outcome: .plain), .shell(ShellCommand(rawValue: "git push -f"))),
            timedOut: true, call: stamp)
        #expect(late.id == "a7c835000001" && late.wouldBe == nil)
        // The hook-local evaluator: the stamp bound on its task.
        let local = DecisionCall.$current.withValue(stamp) {
            DecisionLogRecorder.shellRecord(
                EvaluationResult(outcome: .plain), command: ShellCommand(rawValue: "git push -f"),
                cwd: nil, host: .hook(.codex), home: Self.home, at: Self.now, timedOut: false, session: "abc-123")
        }
        #expect(local == allowed)
        // No stamp: no id, no would-be.
        let bare = Self.record(EvaluationResult(outcome: .plain))
        #expect(bare.id == nil && bare.wouldBe == nil)
        #expect(DecisionStamp().id != DecisionStamp().id)
        #expect(DecisionStamp(id: "a7c835000001").code == "a7c-835")
    }

    @Test func aTappedShellCaptureIsRedactedAndKeepsItsSession() async throws {
        let row = try await Self.written(Self.capture(
            EvaluationResult(outcome: .plain),
            .shell(ShellCommand(rawValue: "API_KEY=sk-live-0123456789abcdef0123 cat /Users/ann/.zshrc"))
        ), timedOut: false)
        #expect(row.session == "abc-123")
        #expect(row.host == .hook(.codex))
        #expect(row.time == Self.now)
        #expect(row.verdict == .allowed)
        #expect(row.command?.contains("sk-live") == false)
        #expect(row.command?.hasSuffix("cat ~/.zshrc") == true)
        #expect(row.cwd == nil)
    }

    /// The reply's final timeout state wins over what the evaluation found,
    /// as it does for the live event.
    @Test func aCaptureWhoseReplyTimedOutIsARefusal() async throws {
        let row = try await Self.written(Self.capture(
            EvaluationResult(outcome: .plain), .shell(ShellCommand(rawValue: "ls"))
        ), timedOut: true)
        #expect(row.verdict == .refused)
        #expect(row.rule == HookDecisionTap.Capture.timeoutRule)
    }

    @Test func aFileCaptureKeepsOnlyItsRedactedPath() async throws {
        let action = FileToolAction(kind: .read, path: FileToolPath(rawValue: "/Users/ann/work/.env"))
        let row = try await Self.written(Self.capture(EvaluationResult(outcome: .plain), .file(action)), timedOut: false)
        #expect(row.tool == .file(.read))
        #expect(row.path == "~/work/.env")
        #expect(row.command == nil)
    }

    @Test func liveRecorderWritesTheConfigDirectoryLog() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rv-decisions-home-\(UUID().uuidString)")
        let home = try #require(HomeDirectory(validating: base.path))
        let live = DecisionLogRecorder.live(home: home, clock: { Self.now })
        let recorder = try #require(live)
        recorder.write(Self.record(EvaluationResult(outcome: .plain)))
        let log = DecisionLog(configDirectory: RVPolicyPaths.configDirectory(home: home))
        #expect(log.records(since: .distantPast, now: Self.now).map(\.command) == ["git push"])
        let homeless = DecisionLogRecorder.live(home: nil, clock: { Self.now })
        #expect(homeless == nil)
    }
}

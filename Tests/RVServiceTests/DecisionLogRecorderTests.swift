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

    @Test func theBoundStampGivesTheIDAndAnAllowsWouldBe() {
        let stamp = DecisionStamp(id: "a7c835000001")
        stamp.note(DecisionWouldBe(verdict: .denied, rule: "core.git:force-push", ask: true))
        let (allowed, denied, late) = DecisionStamp.$current.withValue(stamp) {
            (
                DecisionLogRecorder.shellRecord(
                    EvaluationResult(outcome: .plain), command: ShellCommand(rawValue: "git push -f"),
                    cwd: nil, host: .hook(.claude), home: Self.home, at: Self.now, timedOut: false),
                Self.record(EvaluationResult(outcome: .deny(Deny(ruleID: Self.rule, reason: "no"), matched: nil))),
                DecisionLogRecorder.shellRecord(
                    EvaluationResult(outcome: .plain), command: ShellCommand(rawValue: "git push -f"),
                    cwd: nil, host: .hook(.claude), home: Self.home, at: Self.now, timedOut: true)
            )
        }
        #expect(allowed.id == "a7c835000001")
        #expect(allowed.wouldBe == DecisionWouldBe(verdict: .denied, rule: "core.git:force-push", ask: true))
        // Only an allow carries a would-be; a stop is its own verdict.
        #expect(denied.wouldBe == nil && late.wouldBe == nil)
        #expect(late.id == "a7c835000001")
        #expect(allowed.code == "a7c-835")
        // No stamp bound: no id, no would-be.
        let bare = Self.record(EvaluationResult(outcome: .plain))
        #expect(bare.id == nil && bare.wouldBe == nil)
        #expect(DecisionStamp().id != DecisionStamp().id)
    }

    @Test func shellRowIsRedactedAndCarriesTheBoundSession() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: DecisionRecord.self)
        let recorder = DecisionLogRecorder(home: Self.home) { continuation.yield($0) }
        let session = try #require(SessionID(validating: "abc-123"))
        HookSessionAttribution.$current.withValue(session) {
            recorder.shell(
                EvaluationResult(outcome: .plain),
                command: ShellCommand(rawValue: "API_KEY=sk-live-0123456789abcdef0123 cat /Users/ann/.zshrc"),
                cwd: nil, host: .hook(.codex), at: Self.now
            )
        }
        var iterator = stream.makeAsyncIterator()
        let row = try #require(await iterator.next())
        #expect(row.session == "abc-123")
        #expect(row.command?.contains("sk-live") == false)
        #expect(row.command?.hasSuffix("cat ~/.zshrc") == true)
        #expect(row.cwd == nil)
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

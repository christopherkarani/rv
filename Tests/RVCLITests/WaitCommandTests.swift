import Foundation
import RVDomain
import RVIPC
import RVPolicy
import RVTheme
import Synchronization
import Testing
@testable import RVCLI

/// `rv wait <code>`: reads the unlock ledger and rvd's live events, ends
/// at the person's answer, and says it in the v3 frame's words.
@Suite("rv wait")
struct WaitCommandTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)
    static let code = WaitCode("a7c835")!

    static func row(
        _ kind: WaitLedgerRow.Kind, hash: String = code.codeHash, command: String = "git reset --hard",
        cwd: String = "/tmp/app", at: Date = created
    ) -> WaitLedgerRow {
        WaitLedgerRow(kind: kind, codeHash: hash, commandRedacted: command, cwd: cwd, createdAt: at)
    }

    static var ask: WaitAsk {
        WaitWatch.ask(for: code, in: [row(.pending)])!
    }

    // MARK: Code

    @Test("a code is six hex characters, grouped or not, any case")
    func codeSpellings() {
        #expect(WaitCode("a7c835")?.shown == "a7c835")
        #expect(WaitCode("A7C-835")?.shown == "a7c835")
        #expect(WaitCode(" a7c835\n")?.shown == "a7c835")
        #expect(WaitCode("a7c83") == nil)
        #expect(WaitCode("a7c83g") == nil)
        #expect(WaitCode("a7c8355") == nil)
        #expect(WaitCode("") == nil)
    }

    // MARK: Ledger states

    @Test("a pending code is still waiting")
    func pendingWaits() {
        #expect(WaitWatch.state(of: Self.ask, in: [Self.row(.pending)]) == .waiting)
    }

    @Test("the code turning granted is an unlock in the terminal")
    func grantedIsUnlocked() {
        #expect(WaitWatch.state(of: Self.ask, in: [Self.row(.granted)]) == .unlocked(.code))
    }

    @Test("a spent code says it already ran")
    func consumedIsAlreadyUsed() {
        #expect(WaitWatch.state(of: Self.ask, in: [Self.row(.consumed)]) == .alreadyUsed)
    }

    @Test("the review window approving the same command in the same folder is an unlock")
    func reviewApprovalIsUnlocked() {
        let review = Self.row(.granted, hash: "pending:ABC", at: Self.created.addingTimeInterval(30))
        #expect(WaitWatch.state(of: Self.ask, in: [Self.row(.pending), review]) == .unlocked(.review))
    }

    @Test("a review approval for another folder, another command, or from before the stop is not this one")
    func otherReviewApprovalsDoNotCount() {
        let later = Self.created.addingTimeInterval(30)
        let others = [
            Self.row(.granted, hash: "pending:1", cwd: "/tmp/other", at: later),
            Self.row(.granted, hash: "pending:2", command: "git clean -fd", at: later),
            Self.row(.granted, hash: "pending:3", at: Self.created.addingTimeInterval(-30)),
            // Another code's unlock for the same command is not a review row.
            Self.row(.granted, hash: sha256Hex("bbbbbb"), at: later),
        ]
        #expect(WaitWatch.state(of: Self.ask, in: [Self.row(.pending)] + others) == .waiting)
    }

    @Test("the code leaving the ledger with no answer is expired")
    func goneIsExpired() {
        #expect(WaitWatch.state(of: Self.ask, in: []) == .expired)
    }

    @Test("a code the ledger never had is unknown")
    func unknownCode() {
        #expect(WaitWatch.ask(for: Self.code, in: [Self.row(.pending, hash: sha256Hex("bbbbbb"))]) == nil)
    }

    // MARK: The loop

    @Test("waits through polls, then ends at the unlock with exit 0")
    func loopEndsAtUnlock() async {
        let ledger = ScriptedLedger([[Self.row(.pending)], [Self.row(.pending)], [Self.row(.pending)], [Self.row(.granted)]])
        let events = ScriptedEvents(stream: UUID())
        let (ending, _) = await Self.run(ledger: ledger, events: events).wait(for: Self.code)
        #expect(ending == .finished(.unlocked(.code)))
        #expect(ending.exitCode == 0)
        #expect(events.polls.count == 2)
        // The cursor read from one poll goes back on the next.
        #expect(events.polls.last?.after == 7)
        #expect(events.polls.last?.stream == events.stream)
    }

    @Test("rvd restarting mid-wait ends it: the code died with rvd's memory")
    func restartEndsTheWait() async {
        let ledger = ScriptedLedger([[Self.row(.pending)]])
        let events = ScriptedEvents(stream: UUID(), restartAfter: 1)
        let (ending, _) = await Self.run(ledger: ledger, events: events).wait(for: Self.code)
        #expect(ending == .finished(.rvdRestarted))
        #expect(ending.exitCode == 1)
    }

    @Test("with no answer by the limit it is still waiting, exit 1")
    func limitEndsAsStillWaiting() async {
        let ledger = ScriptedLedger([[Self.row(.pending)]])
        let fake = FakeClock()
        var run = Self.run(ledger: ledger, events: ScriptedEvents(stream: UUID(), clock: fake), limit: .seconds(5))
        run.monotonic = { fake.now }
        let (ending, waited) = await run.wait(for: Self.code)
        #expect(ending == .stillWaiting)
        #expect(ending.exitCode == 1)
        #expect(waited >= .seconds(5))
    }

    @Test("an rvd without events, or no rvd, still ends at the unlock, from the ledger alone")
    func noEventsStillWorks() async {
        let ledger = ScriptedLedger([[Self.row(.pending)], [Self.row(.pending)], [Self.row(.granted)]])
        let slept = Mutex(0)
        var run = WaitRun(ledger: ledger, events: UnavailableEvents(), limit: .seconds(100))
        run.sleep = { _ in slept.withLock { $0 += 1 } }
        let (ending, _) = await run.wait(for: Self.code)
        #expect(ending == .finished(.unlocked(.code)))
        #expect(slept.withLock { $0 } == 1)
    }

    @Test("an unknown code ends at once with exit 2 and no poll")
    func unknownEndsAtOnce() async {
        let events = ScriptedEvents(stream: UUID())
        let (ending, _) = await Self.run(ledger: ScriptedLedger([[]]), events: events).wait(for: Self.code)
        #expect(ending == .unknownCode)
        #expect(ending.exitCode == 2)
        #expect(events.polls.isEmpty)
    }

    // MARK: Words

    @Test("the frame's words, one idea per line, the next command last")
    func screenWords() {
        func text(_ ending: WaitEnding) -> [String] {
            WaitScreen.lines(ending, code: Self.code, owner: "Chris", waited: .seconds(72), palette: colorOffPalette)
        }
        #expect(text(.finished(.unlocked(.code))) == ["✓ Chris unlocked it (1m 12s). Retry the exact command."])
        #expect(text(.finished(.unlocked(.review))) == ["✓ Chris unlocked it (1m 12s). Retry the exact command."])
        #expect(text(.finished(.alreadyUsed)) == [
            "✓ Chris unlocked it, and it already ran once.",
            "Running it again needs a new unlock.",
        ])
        #expect(text(.finished(.expired)) == [
            "✕ Code a7c835 expired before Chris answered.",
            "Retry the exact command for a new code.",
        ])
        #expect(text(.finished(.rvdRestarted)) == [
            "✕ rv restarted, so code a7c835 no longer works.",
            "Retry the exact command for a new code.",
        ])
        #expect(text(.stillWaiting) == ["⏺ Still waiting on Chris (1m 12s).", "→ rv wait a7c835"])
        #expect(text(.unknownCode) == ["✕ rv has no stop with code a7c835.", "Use the code from rv's stop message."])
    }

    @Test("the wait starts with the three check words the menu bar's sheet shows (K2)")
    func startLineCarriesTheCheckWords() {
        #expect(WaitScreen.startLine(code: Self.code, owner: "Chris", palette: colorOffPalette)
            == "⏺ Waiting on Chris · check words: orchid · rocket · crane")
    }

    @Test("the start line goes out once the code is known, and never for an unknown code")
    func startRunsOnlyForALiveStop() async {
        let starts = Mutex(0)
        var known = Self.run(ledger: ScriptedLedger([[Self.row(.pending)], [Self.row(.granted)]]),
                             events: ScriptedEvents(stream: UUID()))
        known.onStart = { starts.withLock { $0 += 1 } }
        _ = await known.wait(for: Self.code)
        #expect(starts.withLock { $0 } == 1)
        var unknown = Self.run(ledger: ScriptedLedger([[]]), events: ScriptedEvents(stream: UUID()))
        unknown.onStart = { starts.withLock { $0 += 1 } }
        _ = await unknown.wait(for: Self.code)
        #expect(starts.withLock { $0 } == 1)
    }

    @Test("durations read as the frame writes them")
    func clockWords() {
        #expect(WaitScreen.clock(.seconds(40)) == "40s")
        #expect(WaitScreen.clock(.seconds(72)) == "1m 12s")
        #expect(WaitScreen.clock(.seconds(3_900)) == "1h 5m")
    }

    @Test("the owner is the account's first name, or The owner")
    func ownerName() {
        #expect(WaitOwnerName.from(fullName: "Chris Karani") == "Chris")
        #expect(WaitOwnerName.from(fullName: "Chris Karani,,,") == "Chris")
        #expect(WaitOwnerName.from(fullName: "") == "The owner")
        #expect(WaitOwnerName.from(fullName: nil) == "The owner")
        #expect(WaitOwnerName.from(fullName: "\u{1B}[31m") == "The owner")
    }

    // MARK: Helpers

    static func run(ledger: any WaitLedger, events: any WaitEvents, limit: Duration = .seconds(100)) -> WaitRun {
        var run = WaitRun(ledger: ledger, events: events, limit: limit)
        run.sleep = { _ in }
        return run
    }
}

/// Serves ledger snapshots in order, then repeats the last.
final class ScriptedLedger: WaitLedger {
    private let snapshots: Mutex<[[WaitLedgerRow]]>

    init(_ snapshots: [[WaitLedgerRow]]) {
        self.snapshots = Mutex(snapshots)
    }

    func rows(now: Date) async -> [WaitLedgerRow] {
        snapshots.withLock { list in
            list.count > 1 ? list.removeFirst() : (list.first ?? [])
        }
    }
}

final class FakeClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ by: Duration) { instant.withLock { $0 = $0.advanced(by: by) } }
}

/// Answers every poll with no events at `stream` (cursor 7); after
/// `restartAfter` polls, a new stream with `resync`.
final class ScriptedEvents: WaitEvents {
    let stream: UUID
    private let restartAfter: Int?
    private let clock: FakeClock?
    private let seen = Mutex<[EventsParams]>([])

    init(stream: UUID, restartAfter: Int? = nil, clock: FakeClock? = nil) {
        self.stream = stream
        self.restartAfter = restartAfter
        self.clock = clock
    }

    var polls: [EventsParams] { seen.withLock { $0 } }

    func poll(_ params: EventsParams) async -> WaitPoll {
        let count = seen.withLock { $0.append(params); return $0.count }
        clock?.advance(.milliseconds(params.waitMs ?? 0))
        if let restartAfter, count > restartAfter {
            return .events(EventsReply(stream: UUID(), cursor: 0, resync: true, events: []))
        }
        return .events(EventsReply(stream: stream, cursor: 7, events: []))
    }
}

struct UnavailableEvents: WaitEvents {
    func poll(_ params: EventsParams) async -> WaitPoll { .unavailable }
}

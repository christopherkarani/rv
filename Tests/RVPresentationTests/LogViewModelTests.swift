import Foundation
import Testing
import RVDomain
@testable import RVPresentation

@Suite("rv log view model")
struct LogViewModelTests {
    static let now = Date(timeIntervalSince1970: 1_795_357_800) // 2026-11-22 14:30 UTC
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func entry(
        minutesAgo: Double, agent: String = "claude", stopped: Bool, rule: String = "core.git:reset-hard",
        judge: Bool = false, tool: String = "Bash", target: String = "", wouldAsk: Bool = false
    ) -> LogEntry {
        LogEntry(
            time: now.addingTimeInterval(-minutesAgo * 60), agent: agent, stopped: stopped, wouldAsk: wouldAsk,
            rule: rule, isJudge: judge, tool: tool, target: target, code: "abc-\(Int(minutesAgo) % 1000)"
        )
    }

    func model(_ entries: [LogEntry], _ query: LogQuery = LogQuery()) -> LogViewModel {
        LogViewModel(entries: entries, query: query, now: Self.now, calendar: Self.utc)
    }

    @Test("a stop and a would-stop never share a word or a glyph")
    func stoppedAndWouldStopAreDistinct() {
        #expect(LogVerdict.stopped.label == "✕ Stopped")
        #expect(LogVerdict.wouldStop.label == "◐ Would stop")
        let rows = model([Self.entry(minutesAgo: 1, stopped: true), Self.entry(minutesAgo: 2, stopped: false)]).rows
        #expect(rows.map(\.verdict) == [.stopped, .wouldStop])
    }

    @Test("newest first, the newest 20 by default, every row with --all")
    func limitAndOrder() {
        let entries = (0..<25).map { Self.entry(minutesAgo: Double($0), stopped: $0 % 2 == 0) }.shuffled()
        let shown = model(entries)
        #expect(shown.rows.count == LogQuery.defaultLimit)
        #expect(shown.rows.map(\.time) == shown.rows.map(\.time).sorted(by: >))
        #expect(shown.matching == 25)
        #expect(shown.countLabel == "20 of 25")
        #expect(shown.stopped == 13 && shown.wouldStop == 12)
        #expect(shown.next?.command == "rv log --all")
        let all = model(entries, LogQuery(all: true))
        #expect(all.rows.count == 25)
        #expect(all.countLabel == "25")
        #expect(all.next == nil)
    }

    @Test("judge notes in shadow fold into the summary line, not one row each")
    func judgeNotesFold() {
        let entries = [Self.entry(minutesAgo: 1, stopped: true)]
            + (2..<43).map { Self.entry(minutesAgo: Double($0), stopped: false, rule: "core.judge:laya-block", judge: true) }
        let folded = model(entries)
        #expect(folded.rows.count == 1)
        #expect(folded.judgeNotesHidden == 41)
        #expect(folded.summary == "1 stopped · 0 would stop · judge: 41 notes in shadow, hidden")
        #expect(folded.next?.command == "rv log --all")
        #expect(folded.next?.why == "every row, judge notes too")
        #expect(model(entries, LogQuery(all: true)).rows.count == 20 + 22)
        #expect(model(entries, LogQuery(rule: "judge")).rows.count == 20)
        #expect(model(entries, LogQuery(rule: "judge")).judgeNotesHidden == 0)
    }

    @Test("a judge stop that really stopped stays a row")
    func enforcedJudgeStopIsARow() {
        let rows = model([Self.entry(minutesAgo: 1, stopped: true, rule: "core.judge:laya-block", judge: true)]).rows
        #expect(rows.count == 1)
        #expect(rows.first?.verdict == .stopped)
    }

    @Test("--rule matches part of the id and --host the whole agent, any case")
    func filters() {
        let entries = [
            Self.entry(minutesAgo: 1, agent: "claude", stopped: true, rule: "core.git:reset-hard"),
            Self.entry(minutesAgo: 2, agent: "codex", stopped: false, rule: "core.git:push-force-long"),
            Self.entry(minutesAgo: 3, agent: "claude", stopped: false, rule: "core.secrets:env", tool: "Read", target: "~/.env"),
        ]
        #expect(model(entries, LogQuery(rule: "CORE.GIT")).rows.map(\.agent) == ["claude", "codex"])
        #expect(model(entries, LogQuery(host: "Claude")).rows.map(\.rule) == ["core.git:reset-hard", "core.secrets:env"])
        #expect(model(entries, LogQuery(host: "clau")).rows.isEmpty)
        let none = model(entries, LogQuery(rule: "nothing"))
        #expect(none.emptyMessage == "Nothing matches.")
        #expect(none.next?.command == "rv log")
        let cut = model((0..<30).map { Self.entry(minutesAgo: Double($0), stopped: true) }, LogQuery(rule: "it's", host: "claude"))
        #expect(cut.rows.isEmpty)
        let more = model((0..<30).map { Self.entry(minutesAgo: Double($0), stopped: true) }, LogQuery(rule: "core.git", host: "claude"))
        #expect(more.next?.command == "rv log --all --rule core.git --host claude")
    }

    @Test("the command is the target, or the tool when the ledger kept none")
    func commandCell() {
        let rows = model([
            Self.entry(minutesAgo: 1, stopped: true),
            Self.entry(minutesAgo: 2, stopped: true, tool: "Read", target: "~/.ssh/id_ed25519"),
            Self.entry(minutesAgo: 3, stopped: true, target: "git reset --hard"),
        ]).rows
        #expect(rows.map(\.command) == ["Bash", "Read ~/.ssh/id_ed25519", "git reset --hard"])
    }

    @Test("time is the clock; a row from an earlier day also names its day")
    func timeLabels() {
        let rows = model([
            Self.entry(minutesAgo: 28, stopped: true),
            Self.entry(minutesAgo: 60 * 24 + 18, stopped: true),
        ]).rows
        #expect(rows.map(\.timeLabel) == ["14:02", "14:12"])
        #expect(rows.map(\.dayLabel) == [nil, "Sat 21 Nov"])
        #expect(model([Self.entry(minutesAgo: 28, stopped: true)]).spanLabel == "today")
        #expect(model([Self.entry(minutesAgo: 60 * 24, stopped: true)]).spanLabel == "last 7 days")
    }

    @Test("empty, filtered and switched-off logs each say so")
    func emptyStates() {
        #expect(model([]).emptyMessage == "Nothing stopped, nothing would stop in the last 7 days.")
        #expect(model([]).next == nil)
        let off = LogViewModel(entries: [], query: LogQuery(), now: Self.now, calendar: Self.utc, ledgerOff: true)
        #expect(off.emptyMessage?.hasPrefix("The log is off") == true)
    }

    @Test("--json carries the rows shown and the summary counts")
    func robotPayload() throws {
        let payload = LogRobotPayload(model([
            Self.entry(minutesAgo: 1, stopped: true),
            Self.entry(minutesAgo: 2, stopped: false, wouldAsk: true),
            Self.entry(minutesAgo: 3, stopped: false, rule: "core.judge:laya-block", judge: true),
        ]))
        #expect(payload.schema == "rv.log.v1")
        #expect(payload.rows.map(\.verdict) == [.stopped, .wouldStop])
        #expect(payload.rows.map(\.wouldBe) == [nil, "ask"])
        #expect(payload.judgeNotesHidden == 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: encoder.encode(payload), encoding: .utf8))
        #expect(json.hasPrefix(#"{"judge_notes_hidden":1,"matching":2,"rows":[{"agent":"claude","code":"abc-1","command":"Bash","rule":"core.git:reset-hard","target":"","time":"2026-11-22T14:29:00Z","tool":"Bash","verdict":"stopped"}"#))
        #expect(json.contains(#""verdict":"would_stop","would_be":"ask""#))
        #expect(json.hasSuffix(#""schema":"rv.log.v1","stopped":1,"would_stop":1}"#))
    }
}

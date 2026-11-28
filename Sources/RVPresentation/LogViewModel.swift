import Foundation
import RVDomain

/// One decision as `rv log` reads it. The CLI builds these from rvd's
/// decision log, or the denial ledger when there is none; nothing here
/// reads a file. The ledger keeps no command text, so `command` is nil on
/// its rows. `target` is the redacted path for a file tool.
public struct LogEntry: Equatable, Sendable {
    public var time: Date
    /// Host raw value (`claude`, `codex`, `tty`).
    public var agent: String
    /// `false` for an observed row: watch mode let it run.
    public var stopped: Bool
    /// Observed rows: guarding would have asked a human, not stopped it.
    public var wouldAsk: Bool
    public var rule: String
    /// The rule is the judge's (`core.judge`), not a pack pattern.
    public var isJudge: Bool
    /// `Bash`, `Read`, `Edit` or `Write`.
    public var tool: String
    public var target: String
    /// The shell command as the decision log recorded it, redacted; nil
    /// when nothing was recorded.
    public var command: String?
    /// The call's code (`a7c-835`); nil when its row carries no id.
    public var code: String?
    public var session: String?
    /// The call's full id (12 hex digits) the code is cut from, or nil.
    public var id: String?

    public init(
        time: Date, agent: String, stopped: Bool, wouldAsk: Bool = false, rule: String,
        isJudge: Bool = false, tool: String, target: String, command: String? = nil, code: String?,
        session: String? = nil, id: String? = nil
    ) {
        self.time = time
        self.agent = agent
        self.stopped = stopped
        self.wouldAsk = wouldAsk
        self.rule = rule
        self.isJudge = isJudge
        self.tool = tool
        self.target = target
        self.command = command
        self.code = code
        self.session = session
        self.id = id
    }

    /// A judge note in shadow: the judge's own would-stop, which watch
    /// mode let run. `rv log` folds these into one count.
    public var isShadowJudgeNote: Bool { isJudge && stopped == false }
}

/// What `rv log` was asked for.
public struct LogQuery: Equatable, Sendable {
    /// Rows shown without `--all`.
    public static let defaultLimit = 20

    /// Every row, judge notes included, with no limit.
    public var all: Bool
    /// Only rules whose id contains this text, any case.
    public var rule: String?
    /// Only this host, any case.
    public var host: String?

    public init(all: Bool = false, rule: String? = nil, host: String? = nil) {
        self.all = all
        self.rule = rule
        self.host = host
    }

    public var isFiltered: Bool { rule != nil || host != nil }

    func matches(_ entry: LogEntry) -> Bool {
        if let rule, entry.rule.localizedCaseInsensitiveContains(rule) == false { return false }
        if let host, entry.agent.caseInsensitiveCompare(host) != .orderedSame { return false }
        return true
    }

    /// Judge notes fold away unless the reader asked for every row or
    /// named a rule (`--rule core.judge` shows them).
    var foldsJudgeNotes: Bool { all == false && rule == nil }
}

/// What happened to one command, in the v5c event words.
public enum LogVerdict: String, Equatable, Sendable, Encodable {
    /// It did not run (guarding, or a stop that holds in every mode).
    case stopped
    /// Watch mode let it run; guarding would have stopped it.
    case wouldStop = "would_stop"

    public var glyph: CommandVocabulary.Glyph {
        switch self {
        case .stopped: .stopped
        case .wouldStop: .watched
        }
    }

    /// `✕ Stopped`, `◐ Would stop`.
    public var label: String {
        let word = glyph.eventWord ?? glyph.word
        return glyph.rawValue + " " + word.prefix(1).uppercased() + word.dropFirst()
    }
}

/// One `rv log` row: time, agent, verdict, rule, command, code.
public struct LogRow: Equatable, Sendable {
    public var time: Date
    /// `14:02`, local time.
    public var timeLabel: String
    /// `Sat 21 Nov` for a row from an earlier day; nil for today. The
    /// renderer puts it on its own line above that day's rows.
    public var dayLabel: String?
    public var agent: String
    public var verdict: LogVerdict
    public var wouldAsk: Bool
    public var rule: String
    /// What ran or would have, as the command cell shows it: the recorded
    /// command, else the target, else the tool (`Bash`,
    /// `Read ~/.ssh/id_ed25519`).
    public var command: String
    /// The shell command the decision log recorded, or nil.
    public var recordedCommand: String?
    public var tool: String
    public var target: String
    public var code: String?
    public var session: String?
}

/// `rv log`: the newest decisions in fixed columns, one summary line.
public struct LogViewModel: Equatable, Sendable {
    /// What the header names, and what the counts cover: one day, the
    /// whole window, or a shorter stretch when the source keeps less (the
    /// ledger's row cap).
    public enum Span: Equatable, Sendable {
        case today
        case days(Int)
        /// `since Sat 21 Nov`.
        case since(String)
    }

    /// Shown rows, newest first.
    public var rows: [LogRow]
    /// Rows that match the query and are not folded away.
    public var matching: Int
    /// Of `matching`: stopped and would-stop.
    public var stopped: Int
    public var wouldStop: Int
    /// Judge notes folded into the summary line.
    public var judgeNotesHidden: Int
    public var span: Span
    public var query: LogQuery
    /// `blocks.enabled` is false: rv keeps no rows.
    public var ledgerOff: Bool
    /// rvd's decision log was there to read: shell rows can show their
    /// command. False for an older rvd or `decisions.enabled: false`.
    public var commandsRecorded: Bool
    /// Decision-log day files (`yyyy-MM-dd`) not read for their size.
    public var skippedDays: [String]

    /// - Parameters:
    ///   - entries: decisions, any order. Those older than `windowDays`
    ///     are left out, so the rows, counts and header cover one window.
    ///   - windowDays: how many days rv keeps.
    ///   - coveredFrom: the oldest time the source still holds, when it
    ///     keeps less than the window (the ledger at its row cap).
    ///   - calendar: its time zone sets the time column.
    public init(
        entries: [LogEntry], query: LogQuery, now: Date, calendar: Calendar,
        windowDays: Int = 7, coveredFrom: Date? = nil, ledgerOff: Bool = false,
        commandsRecorded: Bool = true, skippedDays: [String] = []
    ) {
        let windowStart = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let newestFirst = entries
            .filter { $0.time >= windowStart && query.matches($0) }
            .sorted { $0.time > $1.time }
        let folds = query.foldsJudgeNotes
        let listed = folds ? newestFirst.filter { $0.isShadowJudgeNote == false } : newestFirst
        let shown = query.all ? listed : Array(listed.prefix(LogQuery.defaultLimit))
        let allToday = listed.allSatisfy { calendar.isDate($0.time, inSameDayAs: now) }
        self.rows = shown.map { Self.row($0, now: now, calendar: calendar) }
        self.matching = listed.count
        self.stopped = listed.filter(\.stopped).count
        self.wouldStop = listed.count - stopped
        self.judgeNotesHidden = folds ? newestFirst.count - listed.count : 0
        if listed.isEmpty == false, allToday {
            self.span = .today
        } else if let coveredFrom, coveredFrom > windowStart {
            self.span = .since(Self.dayLabel(coveredFrom, calendar: calendar))
        } else {
            self.span = .days(windowDays)
        }
        self.query = query
        self.ledgerOff = ledgerOff
        self.commandsRecorded = commandsRecorded
        self.skippedDays = skippedDays
    }

    /// Shell rows are listed but rvd recorded no commands for them.
    public var commandsMissing: Bool {
        commandsRecorded == false && rows.contains { $0.tool == "Bash" }
    }

    /// One dim line when decision-log days were too large to read, or nil.
    public var skippedNote: String? {
        guard skippedDays.isEmpty == false else { return nil }
        let days = skippedDays.count == 1 ? "day" : "days"
        return "Skipped \(skippedDays.count) decision-log \(days) over 64 MB: "
            + skippedDays.joined(separator: ", ") + "."
    }

    /// Something matched but is not on screen: past the limit, or a
    /// folded judge note.
    public var hidesRows: Bool { rows.count < matching || judgeNotesHidden > 0 }

    /// `today`, `last 7 days`, `since Sat 21 Nov`.
    public var spanLabel: String {
        switch span {
        case .today: "today"
        case .days(let days): "last \(days) days"
        case .since(let day): "since \(day)"
        }
    }

    /// `3 of 47`, or `3` when every row is shown.
    public var countLabel: String {
        rows.count < matching ? "\(rows.count) of \(matching)" : "\(matching)"
    }

    /// The one summary line, as parts joined with ` · `: `1 stopped`,
    /// `2 would stop`, `41 judge notes in shadow` (folded away), and
    /// `commands not recorded` when the decision log is off or missing
    /// (`rv help log` says why).
    public var summaryParts: [String] {
        var parts = ["\(stopped) stopped", "\(wouldStop) would stop"]
        if judgeNotesHidden > 0 {
            parts.append("\(judgeNotesHidden) judge \(judgeNotesHidden == 1 ? "note" : "notes") in shadow")
        }
        if commandsMissing {
            parts.append("commands not recorded")
        }
        return parts
    }

    public var summary: String { summaryParts.joined(separator: " · ") }

    /// What to say when no row is listed, or nil when there are rows.
    public var emptyMessage: String? {
        guard rows.isEmpty else { return nil }
        if ledgerOff {
            return "The log is off, so rv keeps no rows. blocks.enabled in ~/.config/rv/config.json turns it on."
        }
        if query.isFiltered { return "Nothing matches." }
        if judgeNotesHidden > 0 { return "Nothing stopped, nothing would stop." }
        return "Nothing stopped, nothing would stop in the \(spanLabel)."
    }

    /// The next command and why, or nil when nothing is hidden.
    public var next: (command: String, why: String)? {
        let log = CommandVocabulary.program + " log"
        if rows.isEmpty, query.isFiltered { return (log, "every row") }
        guard hidesRows, query.all == false else { return nil }
        var all = log + " --all"
        if let rule = query.rule { all += " --rule " + Self.shellWord(rule) }
        if let host = query.host { all += " --host " + Self.shellWord(host) }
        return (all, judgeNotesHidden > 0 ? "every row, judge notes too" : "every row")
    }

    private static func shellWord(_ text: String) -> String {
        let plain = text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || ".:_-/".unicodeScalars.contains(scalar)
        }
        return plain && text.isEmpty == false ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Cells keep their raw text; the renderer escapes them for the
    /// terminal and `--json` encodes them as they are.
    private static func row(_ entry: LogEntry, now: Date, calendar: Calendar) -> LogRow {
        let command: String
        if let recorded = entry.command, recorded.isEmpty == false {
            command = recorded
        } else if entry.target.isEmpty {
            command = entry.tool
        } else {
            command = entry.tool == "Bash" ? entry.target : entry.tool + " " + entry.target
        }
        return LogRow(
            time: entry.time,
            timeLabel: timeLabel(entry.time, calendar: calendar),
            dayLabel: calendar.isDate(entry.time, inSameDayAs: now) ? nil : dayLabel(entry.time, calendar: calendar),
            agent: entry.agent,
            verdict: entry.stopped ? .stopped : .wouldStop,
            wouldAsk: entry.stopped == false && entry.wouldAsk,
            rule: entry.rule,
            command: command,
            recordedCommand: entry.command.flatMap { $0.isEmpty ? nil : $0 },
            tool: entry.tool,
            target: entry.target,
            code: entry.code,
            session: entry.session
        )
    }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func timeLabel(_ time: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `Sat 21 Nov`, in English whatever the locale, like the rest of rv.
    static func dayLabel(_ time: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.weekday, .day, .month], from: time)
        let weekday = parts.weekday.map { weekdays[($0 - 1) % 7] } ?? ""
        let month = parts.month.map { months[($0 - 1) % 12] } ?? ""
        return "\(weekday) \(parts.day ?? 0) \(month)"
    }
}

/// `rv log --json`: the rows `rv log` shows, and the counts behind its
/// summary line. Keys stay stable.
public struct LogRobotPayload: Equatable, Sendable, Encodable {
    public static let schema = "rv.log.v1"

    public struct Row: Equatable, Sendable, Encodable {
        public var time: Date
        public var agent: String
        public var verdict: LogVerdict
        public var rule: String
        /// The recorded shell command, redacted; null when none was.
        public var command: String?
        public var code: String?
        public var tool: String
        public var target: String
        /// Would-stop rows only: `ask` when guarding would have asked.
        public var wouldBe: String?
        public var session: String?

        enum CodingKeys: String, CodingKey {
            case time, agent, verdict, rule, command, code, tool, target, session
            case wouldBe = "would_be"
        }

        /// Every key is always present: a missing value is `null`.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(time, forKey: .time)
            try container.encode(agent, forKey: .agent)
            try container.encode(verdict, forKey: .verdict)
            try container.encode(rule, forKey: .rule)
            try container.encode(command, forKey: .command)
            try container.encode(code, forKey: .code)
            try container.encode(tool, forKey: .tool)
            try container.encode(target, forKey: .target)
            try container.encode(wouldBe, forKey: .wouldBe)
            try container.encode(session, forKey: .session)
        }
    }

    public var schema: String
    public var rows: [Row]
    public var matching: Int
    public var stopped: Int
    public var wouldStop: Int
    public var judgeNotesHidden: Int
    /// False when rvd's decision log was missing or off, so shell rows
    /// carry no command text.
    public var commandsRecorded: Bool
    /// Decision-log days not read for their size.
    public var skippedDays: [String]

    enum CodingKeys: String, CodingKey {
        case schema, rows, matching, stopped
        case wouldStop = "would_stop"
        case judgeNotesHidden = "judge_notes_hidden"
        case commandsRecorded = "commands_recorded"
        case skippedDays = "skipped_days"
    }

    public init(_ model: LogViewModel) {
        schema = Self.schema
        rows = model.rows.map { row in
            Row(
                time: row.time, agent: row.agent, verdict: row.verdict, rule: row.rule,
                command: row.recordedCommand, code: row.code, tool: row.tool, target: row.target,
                wouldBe: row.verdict == .wouldStop ? (row.wouldAsk ? "ask" : "deny") : nil,
                session: row.session
            )
        }
        matching = model.matching
        stopped = model.stopped
        wouldStop = model.wouldStop
        judgeNotesHidden = model.judgeNotesHidden
        commandsRecorded = model.commandsRecorded
        skippedDays = model.skippedDays
    }
}

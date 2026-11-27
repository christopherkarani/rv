import Foundation
import RVHistory

/// rv's mode, in the words rv term shows.
public enum TermMode: Equatable, Sendable {
    /// Enforce: rv stops what its rules stop.
    case guarding
    /// Observe: rv lets everything run and notes what it would have stopped.
    case watching
}

/// One request waiting on a human, as Glance and Needs you show it.
public struct TermAsk: Equatable, Sendable {
    public var agent: String
    /// What it wants to do, already redacted ("git push --force", "write ~/.zshrc").
    public var summary: String
    public var since: Date

    public init(agent: String, summary: String, since: Date) {
        self.agent = agent
        self.summary = summary
        self.since = since
    }
}

/// What one Stream row says happened.
public enum TermEvent: Equatable, Sendable {
    /// ✓ It ran.
    case ran
    /// ◐ It ran, and guarding would have stopped it.
    case wouldStop
    /// ✕ rv stopped it.
    case stopped
}

/// One command (or file action) in the Stream.
public struct TermRow: Equatable, Sendable {
    public var time: Date
    public var event: TermEvent
    public var agent: String
    /// The redacted command, or the tool and path for a file action.
    public var text: String
    public var cwd: String?
    public var rule: String?

    public init(time: Date, event: TermEvent, agent: String, text: String, cwd: String? = nil, rule: String? = nil) {
        self.time = time
        self.event = event
        self.agent = agent
        self.text = text
        self.cwd = cwd
        self.rule = rule
    }
}

/// Everything rv term draws, as a value. The command feeds it what it read
/// (audit events, decision-log rows, pending asks, the mode) and the
/// clock; `TermScreen` turns it into lines. No file, clock or terminal
/// access here.
public struct TermState: Equatable, Sendable {
    /// Stream keeps at most this many rows.
    public static let rowLimit = 500
    /// How close a `command.observed` event and an allowed decision row
    /// must be to be the same command.
    static let pairingWindow: TimeInterval = 2

    public var mode: TermMode
    public var tally: TermTally
    public private(set) var rows: [TermRow] = []
    public var asks: [TermAsk] = []
    public var navigation: TermNavigation
    /// Stream's `f`: only would-stops and stops.
    public var wouldStopsOnly = false
    /// `?` shows every key.
    public var showingKeys = false
    /// Decision-log rows read today (the "commands checked" count). Nil
    /// until the log has been seen, so an rvd that writes no log shows no
    /// count instead of a wrong zero.
    public private(set) var checkedToday: Int?
    public private(set) var now: Date
    private var countedDay: Date

    public init(now: Date, mode: TermMode = .guarding, start: TermView = .glance, calendar: Calendar = .current) {
        self.now = now
        self.mode = mode
        self.tally = TermTally(now: now, calendar: calendar)
        self.navigation = TermNavigation(start: start)
        self.countedDay = calendar.startOfDay(for: now)
    }

    /// Folds in new audit events: the tally, plus a ◐ / ✕ for Stream.
    /// A would-stop is paired with the allowed decision row it explains
    /// when the decision log has one; a stop is a row of its own unless
    /// the decision log already has the deny.
    public mutating func absorb(audit events: [AuditEvent], now: Date, calendar: Calendar = .current) {
        tick(now, calendar: calendar)
        tally.absorb(events, now: now, calendar: calendar)
        for event in events {
            guard let mark = TermMark(event) else { continue }
            switch mark.verdict {
            case .watched:
                if let index = pairableRow(for: mark, event: .ran) {
                    rows[index].event = .wouldStop
                    rows[index].rule = mark.rule
                } else {
                    insert(TermRow(time: mark.time, event: .wouldStop, agent: mark.agent ?? "terminal",
                                   text: mark.path.map { "file \($0)" } ?? "(command not logged)", rule: mark.rule))
                }
            case .stopped:
                guard pairableRow(for: mark, event: .stopped) == nil else { continue }
                insert(TermRow(time: mark.time, event: .stopped, agent: mark.agent ?? "terminal",
                               text: mark.path.map { "file \($0)" } ?? "(command not logged)", rule: mark.rule))
            }
        }
        trim()
    }

    /// Folds in new decision-log rows.
    public mutating func absorb(decisions records: [DecisionRecord], now: Date, calendar: Calendar = .current) {
        tick(now, calendar: calendar)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: countedDay) ?? countedDay.addingTimeInterval(86_400)
        var checked = checkedToday ?? 0
        for record in records {
            if record.time >= countedDay, record.time < dayEnd { checked += 1 }
            let event: TermEvent = record.verdict == .allowed ? .ran : .stopped
            var row = TermRow(
                time: record.time, event: event, agent: Self.agentName(record.host),
                text: Self.text(of: record), cwd: record.cwd, rule: record.rule)
            // An audit row that arrived first and stood in for this command.
            if let index = rows.firstIndex(where: {
                $0.text == "(command not logged)" && abs($0.time.timeIntervalSince(record.time)) <= Self.pairingWindow
                    && ($0.event == .wouldStop && event == .ran || $0.event == .stopped && event == .stopped)
            }) {
                row.event = rows[index].event
                row.rule = rows[index].rule ?? row.rule
                rows.remove(at: index)
            }
            insert(row)
        }
        checkedToday = checked
        trim()
    }

    /// Moves the clock on: a new day restarts the count.
    public mutating func tick(_ now: Date, calendar: Calendar = .current) {
        self.now = now
        tally.advance(to: now, calendar: calendar)
        let day = calendar.startOfDay(for: now)
        if day != countedDay {
            countedDay = day
            if checkedToday != nil {
                checkedToday = rows.filter { $0.time >= day && $0.text != "(command not logged)" }.count
            }
        }
    }

    /// Stream's rows, newest last, with `f` applied.
    public var streamRows: [TermRow] {
        wouldStopsOnly ? rows.filter { $0.event != .ran } : rows
    }

    /// The newest row.
    public var latest: TermRow? { rows.last }

    private func pairableRow(for mark: TermMark, event: TermEvent) -> Int? {
        rows.lastIndex(where: {
            $0.event == event && $0.text != "(command not logged)"
                && abs($0.time.timeIntervalSince(mark.time)) <= Self.pairingWindow
                && (event != .stopped || $0.rule == mark.rule)
        })
    }

    private mutating func insert(_ row: TermRow) {
        if let last = rows.last, last.time > row.time {
            let index = rows.lastIndex(where: { $0.time <= row.time }).map { $0 + 1 } ?? 0
            rows.insert(row, at: index)
        } else {
            rows.append(row)
        }
    }

    private mutating func trim() {
        if rows.count > Self.rowLimit { rows.removeFirst(rows.count - Self.rowLimit) }
    }

    static func agentName(_ host: LedgerHost) -> String {
        switch host {
        case .tty: "terminal"
        case .hook(let host): host.rawValue
        }
    }

    static func text(of record: DecisionRecord) -> String {
        if let command = record.command { return command }
        let verb: String
        switch record.tool {
        case .bash: verb = "run"
        case .file(let kind): verb = kind.ledgerName.lowercased()
        }
        return [verb, record.path].compactMap { $0 }.joined(separator: " ")
    }
}

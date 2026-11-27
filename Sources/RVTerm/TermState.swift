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
    /// The card's small heading ("Request", "Egress", "MCP tool").
    public var kind: String
    /// The line under it ("in ~/src/rv").
    public var detail: String?

    public init(agent: String, summary: String, since: Date, kind: String = "Request", detail: String? = nil) {
        self.agent = agent
        self.summary = summary
        self.since = since
        self.kind = kind
        self.detail = detail
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
    /// What a row says when only the audit log knew about it.
    public static let notLogged = "(command not logged)"

    /// Stable while the row lives, so the Stream selection can follow it.
    public var id: Int
    public var time: Date
    public var event: TermEvent
    public var agent: String
    /// The redacted command, or the tool and path for a file action.
    public var text: String
    public var cwd: String?
    public var rule: String?

    public init(id: Int = 0, time: Date, event: TermEvent, agent: String, text: String, cwd: String? = nil, rule: String? = nil) {
        self.id = id
        self.time = time
        self.event = event
        self.agent = agent
        self.text = text
        self.cwd = cwd
        self.rule = rule
    }

    /// Whether the decision log had the command itself.
    public var isLogged: Bool { text != Self.notLogged }

    /// What to print for it: the command, or the rule when the command
    /// was never logged.
    public var display: String {
        isLogged ? text : (rule ?? text)
    }

    /// The folder's last name ("rv" for "~/src/rv").
    public var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

/// A sheet over the current view.
public enum TermSheet: Equatable, Sendable {
    /// `?`: every key.
    case keys
    /// `⏎`: why one row ran or stopped.
    case why(rowID: Int)
}

/// Which Stream column the arrows move in, on a screen wide enough for
/// the agents column.
public enum TermStreamFocus: Equatable, Sendable {
    case agents
    case rows
}

/// A short line that takes the headline's place for a moment.
public struct TermMessage: Equatable, Sendable {
    public var text: String
    public var at: Date

    public init(text: String, at: Date) {
        self.text = text
        self.at = at
    }
}

/// A key, already decoded, that rv term acts on.
public enum TermInput: Equatable, Sendable {
    case navigation(TermNavigationKey)
    case up
    case down
    case left
    case right
    case enter
    /// `f`.
    case filter
    /// `?`.
    case keys
    /// `G`.
    case startGuarding
    /// `a`, `d`.
    case allow
    case deny
    /// `q` (closes a sheet first).
    case quit
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
    /// An agent with a row this recent counts as working.
    public static let workingWindow: TimeInterval = 5 * 60
    /// How long Glance leads with a would-stop or stop that just happened.
    public static let recentRiskWindow: TimeInterval = 9
    /// How long a message holds the headline.
    public static let messageWindow: TimeInterval = 3
    /// How long Needs you shows a would-stop or stop in its corner.
    public static let toastWindow: TimeInterval = 4.2
    /// Stream is this wide or wider: the agents column shows.
    public static let agentsColumnWidth = 110
    /// Stream is this wide or wider: the details of the selected row show.
    public static let inspectorWidth = 124

    public var mode: TermMode
    public var tally: TermTally
    /// Oldest first.
    public private(set) var rows: [TermRow] = []
    public var asks: [TermAsk] = []
    public var navigation: TermNavigation
    /// Stream's `f`: only would-stops and stops.
    public var wouldStopsOnly = false
    /// Stream's agent, from the agents column; nil is every agent.
    public var agentFilter: String?
    public var streamFocus: TermStreamFocus = .rows
    /// The selected Stream row; nil follows the newest.
    public var selectedRowID: Int?
    public var sheet: TermSheet?
    public var message: TermMessage?
    /// Decision-log rows read today (the "commands checked" count). Nil
    /// until the log has been seen, so an rvd that writes no log shows no
    /// count instead of a wrong zero.
    public private(set) var checkedToday: Int?
    public private(set) var now: Date
    private var countedDay: Date
    private var nextRowID = 1

    public init(now: Date, mode: TermMode = .guarding, start: TermView = .glance, calendar: Calendar = .current) {
        self.now = now
        self.mode = mode
        self.tally = TermTally(now: now, calendar: calendar)
        self.navigation = TermNavigation(start: start)
        self.countedDay = calendar.startOfDay(for: now)
    }

    /// `?` shows every key.
    public var showingKeys: Bool { sheet == .keys }

    // MARK: - Reading

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
                                   text: mark.path.map { "file \($0)" } ?? TermRow.notLogged, rule: mark.rule))
                }
            case .stopped:
                guard pairableRow(for: mark, event: .stopped) == nil else { continue }
                insert(TermRow(time: mark.time, event: .stopped, agent: mark.agent ?? "terminal",
                               text: mark.path.map { "file \($0)" } ?? TermRow.notLogged, rule: mark.rule))
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
                !$0.isLogged && abs($0.time.timeIntervalSince(record.time)) <= Self.pairingWindow
                    && ($0.event == .wouldStop && event == .ran || $0.event == .stopped && event == .stopped)
            }) {
                row.event = rows[index].event
                row.rule = rows[index].rule ?? row.rule
                if selectedRowID == rows[index].id { selectedRowID = nil }
                rows.remove(at: index)
            }
            insert(row)
        }
        checkedToday = checked
        trim()
    }

    /// Moves the clock on: a new day restarts the count, an old message
    /// clears.
    public mutating func tick(_ now: Date, calendar: Calendar = .current) {
        self.now = now
        tally.advance(to: now, calendar: calendar)
        if let message, now.timeIntervalSince(message.at) > Self.messageWindow { self.message = nil }
        let day = calendar.startOfDay(for: now)
        if day != countedDay {
            countedDay = day
            if checkedToday != nil {
                checkedToday = rows.filter { $0.time >= day && $0.isLogged }.count
            }
        }
    }

    // MARK: - What the views show

    /// Stream's rows, newest first, with `f` and the agent applied.
    public var streamRows: [TermRow] {
        rows.reversed().filter { row in
            (!wouldStopsOnly || row.event != .ran) && (agentFilter.map { row.agent == $0 } ?? true)
        }
    }

    /// The newest row.
    public var latest: TermRow? { rows.last }

    /// The newest would-stop or stop, if it happened within `window`.
    public func recentRisk(within window: TimeInterval) -> TermRow? {
        guard let row = rows.last(where: { $0.event != .ran }),
            now.timeIntervalSince(row.time) <= window
        else { return nil }
        return row
    }

    /// Agents seen in Stream, most recently active first, each with the
    /// folder of its newest row.
    public var agents: [(name: String, project: String?)] {
        var seen: [String] = []
        var projects: [String: String] = [:]
        for row in rows.reversed() where !seen.contains(row.agent) {
            seen.append(row.agent)
            if let project = row.project { projects[row.agent] = project }
        }
        return seen.map { ($0, projects[$0]) }
    }

    /// Agents with a row in the last five minutes.
    public var agentsWorking: Int {
        Set(rows.filter { now.timeIntervalSince($0.time) <= Self.workingWindow }.map(\.agent)).count
    }

    /// Would-stops in the last seven days, for the "Ready to guard" card.
    public var wouldStopThisWeek: Int {
        tally.week.filter { $0.verdict == .watched }.count
    }

    /// The selected row's index in `streamRows`; the newest when nothing
    /// (or something filtered away) was selected.
    public var selectedIndex: Int {
        streamRows.firstIndex { $0.id == selectedRowID } ?? 0
    }

    public func row(id: Int) -> TermRow? {
        rows.first { $0.id == id }
    }

    // MARK: - Keys

    /// Applies one key. Returns false when rv term should quit. `width`
    /// says which Stream columns are on screen.
    @discardableResult
    public mutating func press(_ input: TermInput, width: Int) -> Bool {
        if sheet != nil {
            switch input {
            case .navigation(.escape), .navigation(.space), .enter, .quit, .keys:
                sheet = nil
            default:
                break
            }
            return true
        }
        let view = navigation.current
        let hasAgentsColumn = width >= Self.agentsColumnWidth
        switch input {
        case .quit:
            return false
        case .navigation(.space) where view == .needsYou:
            if let risk = recentRisk(within: Self.toastWindow) {
                navigation.open(.stream)
                agentFilter = nil
                selectedRowID = risk.id
            } else {
                navigation.handle(.space)
            }
        case .navigation(let key):
            navigation.handle(key)
        case .filter:
            navigation.open(.stream)
            wouldStopsOnly.toggle()
            selectedRowID = nil
        case .keys:
            sheet = .keys
        case .startGuarding:
            if mode == .watching {
                message = TermMessage(text: "Starting guarding from rv term comes next", at: now)
            }
        case .allow, .deny:
            if let ask = asks.first, view != .stream {
                message = TermMessage(text: "Answer \(ask.agent) where it asked; answering here comes next", at: now)
            }
        case .enter:
            if view == .glance, let risk = recentRisk(within: Self.recentRiskWindow) {
                sheet = .why(rowID: risk.id)
            } else if view == .stream {
                if hasAgentsColumn, streamFocus == .agents {
                    streamFocus = .rows
                } else if width < Self.inspectorWidth, let row = streamRows[safe: selectedIndex] {
                    sheet = .why(rowID: row.id)
                }
            }
        case .up, .down:
            guard view == .stream else { break }
            let step = input == .down ? 1 : -1
            if hasAgentsColumn, streamFocus == .agents {
                let names = [nil] + agents.map { Optional($0.name) }
                let index = names.firstIndex(of: agentFilter) ?? 0
                agentFilter = names[max(0, min(names.count - 1, index + step))]
                selectedRowID = nil
            } else {
                let list = streamRows
                let index = selectedIndex + step
                if list.indices.contains(index) { selectedRowID = list[index].id }
            }
        case .left:
            if view == .stream, hasAgentsColumn { streamFocus = .agents }
        case .right:
            if view == .stream, hasAgentsColumn { streamFocus = .rows }
        }
        return true
    }

    // MARK: - Rows

    private func pairableRow(for mark: TermMark, event: TermEvent) -> Int? {
        rows.lastIndex(where: {
            $0.event == event && $0.isLogged
                && abs($0.time.timeIntervalSince(mark.time)) <= Self.pairingWindow
                && (event != .stopped || $0.rule == mark.rule)
        })
    }

    private mutating func insert(_ new: TermRow) {
        var row = new
        row.id = nextRowID
        nextRowID += 1
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

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import Foundation
import RVHistory

/// What rv did about a command it would not let pass.
public enum TermVerdict: String, Equatable, Hashable, Sendable {
    /// Observe mode: guarding would have stopped it; it ran (`command.observed`).
    case watched
    /// Guarding stopped it (`command.denied`).
    case stopped
}

/// One would-stop or stop, as Glance pins it on the river and Watched
/// groups it. Only what the audit log records: the rule, the agent's
/// host, and the redacted path, never the command text.
public struct TermMark: Equatable, Hashable, Sendable {
    public var time: Date
    public var verdict: TermVerdict
    public var rule: String
    /// The hook host (`claude-code`, `codex`, ...); nil for a terminal.
    public var agent: String?
    public var path: String?

    public init(time: Date, verdict: TermVerdict, rule: String, agent: String? = nil, path: String? = nil) {
        self.time = time
        self.verdict = verdict
        self.rule = rule
        self.agent = agent
        self.path = path
    }

    /// The mark for a `command.observed` or `command.denied` event; nil
    /// for any other kind.
    public init?(_ event: AuditEvent) {
        let verdict: TermVerdict
        if event.kind == .commandObserved {
            verdict = .watched
        } else if event.kind == .commandDenied {
            verdict = .stopped
        } else {
            return nil
        }
        self.init(time: event.time, verdict: verdict, rule: event.subject, agent: event.agent, path: event.detail["path"])
    }
}

/// How often one rule fired in the week, for the Watched view.
public struct TermRuleCount: Equatable, Sendable {
    public var rule: String
    public var count: Int
    public var last: Date

    public init(rule: String, count: Int, last: Date) {
        self.rule = rule
        self.count = count
        self.last = last
    }
}

/// The running numbers behind Glance, Watched and Week, folded from audit
/// events as they arrive. A value: feed it events and the clock, read the
/// counts. It never reads files and never looks at the real time itself.
public struct TermTally: Equatable, Sendable {
    /// How far back the Glance river reaches.
    public static let riverWindow: TimeInterval = 30 * 60
    /// How far back Watched and Week reach.
    public static let weekWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Midnight, local time, of the day the "today" counts belong to.
    public private(set) var dayStart: Date
    public private(set) var watchedToday = 0
    public private(set) var stoppedToday = 0
    public private(set) var secretMisuseToday = 0
    public private(set) var egressDeniedToday = 0
    /// Every watched and stopped mark of the last week, oldest first.
    public private(set) var week: [TermMark] = []
    /// The time of the newest event absorbed, so a caller can tell the
    /// view is current.
    public private(set) var lastEventTime: Date?

    public init(now: Date, calendar: Calendar = .current) {
        dayStart = calendar.startOfDay(for: now)
    }

    /// Folds `events` in (any order), then drops what fell out of the
    /// week and starts a new "today" if midnight passed.
    public mutating func absorb(_ events: some Sequence<AuditEvent>, now: Date, calendar: Calendar = .current) {
        roll(now: now, calendar: calendar)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        var added = false
        for event in events {
            if lastEventTime.map({ event.time > $0 }) ?? true {
                lastEventTime = event.time
            }
            let today = event.time >= dayStart && event.time < dayEnd
            if let mark = TermMark(event) {
                if today {
                    switch mark.verdict {
                    case .watched: watchedToday += 1
                    case .stopped: stoppedToday += 1
                    }
                }
                if mark.time >= now.addingTimeInterval(-Self.weekWindow) {
                    week.append(mark)
                    added = true
                }
            } else if today, event.kind == .secretMisuse {
                secretMisuseToday += 1
            } else if today, event.kind == .egressDenied {
                egressDeniedToday += 1
            }
        }
        if added {
            week.sort { $0.time < $1.time }
        }
        prune(now: now)
    }

    /// Moves the window on without new events (call it on each clock tick).
    public mutating func advance(to now: Date, calendar: Calendar = .current) {
        roll(now: now, calendar: calendar)
        prune(now: now)
    }

    /// Marks for the Glance river: the last 30 minutes, oldest first.
    public func river(now: Date) -> [TermMark] {
        let from = now.addingTimeInterval(-Self.riverWindow)
        return week.filter { $0.time >= from && $0.time <= now }
    }

    /// Rules by how often they fired this week with `verdict`, most first;
    /// ties go to the most recent.
    public func weekByRule(_ verdict: TermVerdict = .watched) -> [TermRuleCount] {
        var byRule: [String: TermRuleCount] = [:]
        for mark in week where mark.verdict == verdict {
            if var count = byRule[mark.rule] {
                count.count += 1
                count.last = max(count.last, mark.time)
                byRule[mark.rule] = count
            } else {
                byRule[mark.rule] = TermRuleCount(rule: mark.rule, count: 1, last: mark.time)
            }
        }
        return byRule.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : ($0.last != $1.last ? $0.last > $1.last : $0.rule < $1.rule)
        }
    }

    /// Watched and stopped marks per local day of the last seven days,
    /// oldest day first, for the Week bars.
    public func weekByDay(now: Date, calendar: Calendar = .current) -> [(day: Date, watched: Int, stopped: Int)] {
        let today = calendar.startOfDay(for: now)
        var days: [(day: Date, watched: Int, stopped: Int)] = []
        for offset in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            days.append((day: day, watched: 0, stopped: 0))
        }
        for mark in week {
            let day = calendar.startOfDay(for: mark.time)
            guard let index = days.firstIndex(where: { $0.day == day }) else { continue }
            switch mark.verdict {
            case .watched: days[index].watched += 1
            case .stopped: days[index].stopped += 1
            }
        }
        return days
    }

    private mutating func roll(now: Date, calendar: Calendar) {
        let start = calendar.startOfDay(for: now)
        guard start != dayStart else { return }
        dayStart = start
        // Recount today from the week, which still holds today's marks.
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let marks = week.filter { $0.time >= start && $0.time < dayEnd }
        watchedToday = marks.filter { $0.verdict == .watched }.count
        stoppedToday = marks.filter { $0.verdict == .stopped }.count
        secretMisuseToday = 0
        egressDeniedToday = 0
    }

    private mutating func prune(now: Date) {
        let from = now.addingTimeInterval(-Self.weekWindow)
        if let first = week.firstIndex(where: { $0.time >= from }) {
            if first > 0 { week.removeFirst(first) }
        } else {
            week.removeAll()
        }
    }
}

import Foundation

/// The role a piece of text plays on screen. The command maps each to a
/// colour for the terminal's depth; with no colour they are plain text.
public enum TermInk: Equatable, Sendable {
    case plain
    /// Secondary text.
    case soft
    /// Rules, axes, hints.
    case dim
    /// The headline and the current tab.
    case strong
    /// ✓ and "guarding".
    case ok
    /// ◐ and "watching".
    case watch
    /// ✕.
    case stop
    /// ⏺ and agent names.
    case agent
    /// The ◆ mark.
    case accent
}

public struct TermSpan: Equatable, Sendable {
    public var text: String
    public var ink: TermInk

    public init(_ text: String, _ ink: TermInk = .plain) {
        self.text = text
        self.ink = ink
    }
}

/// One screen line, at most the screen's width in characters.
public typealias TermLine = [TermSpan]

/// Draws a `TermState` at a size. Pure: the same state, size and calendar
/// give the same lines, which is what the tests and `rv term --once` read.
public enum TermScreen {
    /// Narrower or shorter than this, rv term draws a one-line note instead.
    public static let minimumWidth = 50
    public static let minimumHeight = 12

    public static func render(
        _ state: TermState, width: Int, height: Int, calendar: Calendar = .current
    ) -> [TermLine] {
        guard width >= minimumWidth, height >= minimumHeight else {
            return pad([[TermSpan(fit("rv term needs at least \(minimumWidth)×\(minimumHeight).", width), .soft)]],
                       height: height)
        }
        var lines = [header(state, width: width, calendar: calendar), [TermSpan(String(repeating: "─", count: width), .dim)]]
        let bodyHeight = height - lines.count - 2
        let body: [TermLine]
        if state.showingKeys {
            body = keys()
        } else {
            switch state.navigation.current {
            case .glance: body = glance(state, width: width, height: bodyHeight, calendar: calendar)
            case .stream: body = stream(state, width: width, height: bodyHeight, calendar: calendar)
            case .needsYou: body = needsYou(state, width: width)
            }
        }
        lines += pad(Array(body.prefix(bodyHeight)), height: bodyHeight)
        lines.append([TermSpan(String(repeating: "─", count: width), .dim)])
        lines.append(footer(state, width: width))
        return lines.map { clip($0, width) }
    }

    /// The Glance sentence: whether anything needs you.
    public static func headline(_ state: TermState) -> String {
        switch state.asks.count {
        case 0: return "Nothing needs you."
        case 1: return "\(state.asks[0].agent) is asking you something."
        default: return "\(state.asks.count) requests need you."
        }
    }

    // MARK: - Views

    static func glance(_ state: TermState, width: Int, height: Int, calendar: Calendar) -> [TermLine] {
        var lines: [TermLine] = [[]]
        lines.append([TermSpan("  " + headline(state), .strong)])
        lines.append([TermSpan("  " + subline(state), .soft)])
        lines.append([])
        if let ask = state.asks.first {
            lines.append([
                TermSpan("  ⏺ ", .agent), TermSpan(ask.agent, .agent), TermSpan(" wants to  ", .soft),
                TermSpan(ask.summary, .plain), TermSpan("  " + ago(ask.since, state.now), .dim),
            ])
            lines.append([TermSpan("    Answer it where \(ask.agent) asked. Press 3 to see every request.", .dim)])
            lines.append([])
        }
        lines.append([TermSpan("  the last 30 minutes", .dim)])
        lines.append([TermSpan("  ", .plain)] + river(state, cells: width - 4))
        let axis = width - 4
        lines.append([TermSpan("  " + "30m ago".padding(toLength: max(0, axis - 3), withPad: " ", startingAt: 0) + "now", .dim)])
        lines.append([])
        lines.append(counts(state))
        if let latest = state.latest {
            lines.append([])
            lines.append([TermSpan("  latest  ", .dim)] + rowSpans(latest, width: width - 10, now: state.now, clock: false, calendar: calendar))
        }
        return lines
    }

    static func stream(_ state: TermState, width: Int, height: Int, calendar: Calendar) -> [TermLine] {
        var lines: [TermLine] = []
        let title = state.wouldStopsOnly ? "  Would-stops and stops only (f shows everything)" : "  Every command, newest last (f: would-stops only)"
        lines.append([TermSpan(title, .dim)])
        let rows = state.streamRows
        if rows.isEmpty {
            lines.append([])
            lines.append([TermSpan(state.wouldStopsOnly ? "  Nothing rv would have stopped yet." : "  No commands yet.", .soft)])
            if state.checkedToday == nil {
                lines.append([TermSpan("  This rvd keeps no decision log yet, so only would-stops and stops show here.", .dim)])
            }
            return lines
        }
        let room = max(0, height - lines.count)
        for row in rows.suffix(room) {
            lines.append([TermSpan("  ", .plain)] + rowSpans(row, width: width - 2, now: state.now, clock: true, calendar: calendar))
        }
        return lines
    }

    static func needsYou(_ state: TermState, width: Int) -> [TermLine] {
        var lines: [TermLine] = [[]]
        guard !state.asks.isEmpty else {
            lines.append([TermSpan("  Nothing needs you.", .strong)])
            lines.append([TermSpan("  When an agent asks to do something rv holds for a person, it shows up here.", .soft)])
            return lines
        }
        lines.append([TermSpan("  " + headline(state), .strong)])
        lines.append([])
        for ask in state.asks.sorted(by: { $0.since < $1.since }) {
            lines.append([
                TermSpan("  ⏺ ", .agent), TermSpan(ask.agent.padding(toLength: 10, withPad: " ", startingAt: 0), .agent),
                TermSpan(fit(ask.summary, max(10, width - 28)), .plain), TermSpan("  " + ago(ask.since, state.now), .dim),
            ])
        }
        lines.append([])
        lines.append([TermSpan("  Answer each one where the agent asked. Answering from here comes next.", .dim)])
        return lines
    }

    static func keys() -> [TermLine] {
        let rows: [(String, String)] = [
            ("1 2 3", "Glance, Stream, Needs you"),
            ("space", "swap Glance and Stream"),
            ("tab", "next view (shift-tab: previous)"),
            ("f", "Stream: would-stops and stops only"),
            ("esc", "back"),
            ("?", "close this list"),
            ("q", "quit"),
        ]
        var lines: [TermLine] = [[], [TermSpan("  Keys", .strong)], []]
        for (key, what) in rows {
            lines.append([TermSpan("  " + key.padding(toLength: 8, withPad: " ", startingAt: 0), .accent), TermSpan(what, .soft)])
        }
        return lines
    }

    // MARK: - Pieces

    static func header(_ state: TermState, width: Int, calendar: Calendar) -> TermLine {
        let left = [TermSpan(" ◆ ", .accent), TermSpan("rv term", .strong)]
        var right: [TermSpan]
        switch state.mode {
        case .guarding: right = [TermSpan("● ", .ok), TermSpan("guarding", .ok)]
        case .watching: right = [TermSpan("◐ ", .watch), TermSpan("watching", .watch)]
        }
        right.append(TermSpan("   " + clock(state.now, calendar: calendar, seconds: false) + " ", .dim))
        let used = length(left) + length(right)
        return left + [TermSpan(String(repeating: " ", count: max(1, width - used)))] + right
    }

    static func footer(_ state: TermState, width: Int) -> TermLine {
        var spans: [TermSpan] = [TermSpan(" ")]
        for view in TermView.allCases {
            let current = view == state.navigation.current && !state.showingKeys
            spans.append(TermSpan("\(view.rawValue) ", current ? .accent : .dim))
            spans.append(TermSpan(view.title, current ? .strong : .soft))
            spans.append(TermSpan("   "))
        }
        spans.append(TermSpan("? keys  q quit", .dim))
        return spans
    }

    static func subline(_ state: TermState) -> String {
        let stopped = state.tally.stoppedToday
        let watched = state.tally.watchedToday
        let checked = state.checkedToday.map { "\($0) \($0 == 1 ? "command" : "commands") checked today" }
        switch state.mode {
        case .guarding:
            let stops = stopped == 0 ? "nothing stopped" : "\(stopped) stopped"
            return "rv is guarding. " + [checked, stops].compactMap { $0 }.joined(separator: ", ") + "."
        case .watching:
            let would = watched == 0 ? "nothing it would have stopped" : "guarding would have stopped \(watched)"
            return "rv is watching. " + [checked, would].compactMap { $0 }.joined(separator: "; ") + "."
        }
    }

    static func counts(_ state: TermState) -> TermLine {
        var spans: [TermSpan] = [TermSpan("  ")]
        if let checked = state.checkedToday {
            spans += [TermSpan("✓ ", .ok), TermSpan("\(checked) checked", .soft), TermSpan("    ")]
        }
        spans += [TermSpan("◐ ", .watch), TermSpan("\(state.tally.watchedToday) would stop", .soft), TermSpan("    ")]
        spans += [TermSpan("✕ ", .stop), TermSpan("\(state.tally.stoppedToday) stopped", .soft), TermSpan("    ")]
        spans += [TermSpan("⏺ ", .agent), TermSpan("\(state.asks.count) \(state.asks.count == 1 ? "ask" : "asks")", .soft)]
        spans.append(TermSpan("   today", .dim))
        return spans
    }

    /// The last 30 minutes in `cells` buckets, oldest left: `·` where
    /// commands ran, `◐` and `✕` where rv would have stopped or stopped one.
    static func river(_ state: TermState, cells: Int) -> [TermSpan] {
        guard cells > 0 else { return [] }
        let window = TermTally.riverWindow
        let from = state.now.addingTimeInterval(-window)
        var buckets = [TermEvent?](repeating: nil, count: cells)
        func place(_ time: Date, _ event: TermEvent) {
            guard time >= from, time <= state.now else { return }
            let index = min(cells - 1, Int(time.timeIntervalSince(from) / window * Double(cells)))
            let rank: (TermEvent?) -> Int = { $0 == .stopped ? 3 : $0 == .wouldStop ? 2 : $0 == .ran ? 1 : 0 }
            if rank(event) > rank(buckets[index]) { buckets[index] = event }
        }
        for row in state.rows { place(row.time, row.event) }
        for mark in state.tally.river(now: state.now) { place(mark.time, mark.verdict == .watched ? .wouldStop : .stopped) }
        return buckets.map { event in
            switch event {
            case nil: TermSpan("·", .dim)
            case .ran: TermSpan("•", .ok)
            case .wouldStop: TermSpan("◐", .watch)
            case .stopped: TermSpan("✕", .stop)
            }
        }
    }

    static func rowSpans(_ row: TermRow, width: Int, now: Date, clock withClock: Bool, calendar: Calendar) -> [TermSpan] {
        let glyph: TermSpan
        switch row.event {
        case .ran: glyph = TermSpan("✓ ", .ok)
        case .wouldStop: glyph = TermSpan("◐ ", .watch)
        case .stopped: glyph = TermSpan("✕ ", .stop)
        }
        var spans: [TermSpan] = []
        if withClock { spans.append(TermSpan(clock(row.time, calendar: calendar, seconds: true) + "  ", .dim)) }
        spans.append(glyph)
        spans.append(TermSpan(fit(row.agent, 8).padding(toLength: 9, withPad: " ", startingAt: 0), .agent))
        let tail = withClock ? (row.cwd.map { "  " + $0 } ?? "") : "  " + ago(row.time, now)
        let note = row.event == .ran ? "" : row.rule.map { "  " + $0 } ?? ""
        let room = max(8, width - length(spans) - tail.count - note.count)
        spans.append(TermSpan(fit(row.text, room).padding(toLength: room, withPad: " ", startingAt: 0), row.event == .ran ? .plain : .strong))
        if !note.isEmpty { spans.append(TermSpan(note, row.event == .stopped ? .stop : .watch)) }
        spans.append(TermSpan(tail, .dim))
        return spans
    }

    static func ago(_ time: Date, _ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(time)))
        switch seconds {
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    static func clock(_ time: Date, calendar: Calendar, seconds: Bool) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: time)
        let hm = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return seconds ? hm + String(format: ":%02d", parts.second ?? 0) : hm
    }

    // MARK: - Fitting

    static func length(_ spans: [TermSpan]) -> Int { spans.reduce(0) { $0 + $1.text.count } }

    /// `text` cut to `width` characters, ending in "…" when cut.
    static func fit(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        guard text.count > width else { return text }
        return String(text.prefix(max(0, width - 1))) + "…"
    }

    static func clip(_ line: TermLine, _ width: Int) -> TermLine {
        var left = width
        var out: TermLine = []
        for span in line where left > 0 {
            if span.text.count <= left {
                out.append(span)
                left -= span.text.count
            } else {
                out.append(TermSpan(String(span.text.prefix(left)), span.ink))
                left = 0
            }
        }
        return out
    }

    static func pad(_ lines: [TermLine], height: Int) -> [TermLine] {
        lines + Array(repeating: [], count: max(0, height - lines.count))
    }
}

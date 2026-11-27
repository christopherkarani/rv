import Foundation

/// Draws a `TermState` at a size, as the v5c mock lays it out: tabs and
/// the mode in the top row, one view, and the keys that view takes on the
/// bottom row. Pure: the same state, size and calendar give the same
/// lines, which is what the tests and `rv term --once` read.
public enum TermScreen {
    /// Narrower or shorter than this, rv term draws a one-line note instead.
    public static let minimumWidth = 50
    public static let minimumHeight = 12

    public static func render(
        _ state: TermState, width: Int, height: Int, calendar: Calendar = .current
    ) -> [TermLine] {
        guard width >= minimumWidth, height >= minimumHeight else {
            var canvas = TermCanvas(width: width, height: height)
            canvas.segs(0, 0, [TermSpan("rv term needs at least \(minimumWidth)×\(minimumHeight).", .soft)], limit: width)
            return canvas.lines()
        }
        var canvas = TermCanvas(width: width, height: height)
        topBar(&canvas, state, calendar: calendar)
        let top = 2
        let room = height - 4
        switch state.navigation.current {
        case .glance: glance(&canvas, state, top: top, room: room)
        case .stream: stream(&canvas, state, top: top, room: room, calendar: calendar)
        case .needsYou: needsYou(&canvas, state, top: top, room: room)
        }
        hints(&canvas, state, row: height - 1)
        if state.navigation.current == .needsYou, state.sheet == nil,
            let risk = state.recentRisk(within: TermState.toastWindow)
        {
            toast(&canvas, risk, bottom: height)
        }
        switch state.sheet {
        case nil: break
        case .keys:
            canvas.fadeAll()
            keysSheet(&canvas, bottom: height)
        case .why(let id):
            if let row = state.row(id: id) {
                canvas.fadeAll()
                whySheet(&canvas, row, bottom: height, calendar: calendar)
            }
        }
        return canvas.lines()
    }

    /// The Glance sentence: whether anything needs you.
    public static func headline(_ state: TermState) -> String {
        if let ask = state.asks.first { return "\(ask.agent) is asking you something." }
        return "Nothing needs you."
    }

    // MARK: - Top and bottom rows

    static func topBar(_ canvas: inout TermCanvas, _ state: TermState, calendar: Calendar) {
        let width = canvas.width
        canvas.put(2, 0, "◆", .rv, bold: true)
        canvas.put(3, 0, " rv", .fg, bold: true)
        let asks = state.asks.count
        let labels = TermView.allCases.map { view in
            "\(view.number) \(view.title)" + (view == .needsYou && asks > 0 ? " \(asks)" : "")
        }
        let total = labels.reduce(0) { $0 + $1.count + 2 } + labels.count - 1
        var x = max(8, (width - total) / 2)
        for (view, label) in zip(TermView.allCases, labels) {
            let on = state.navigation.current == view
            let tab = " " + label + " "
            canvas.put(x, 0, tab, on ? .fg : .mute, bold: on, fill: on ? .sel : nil)
            canvas.put(x + 1, 0, "\(view.number)", on ? .rv : .ghost, bold: on)
            if view == .needsYou, asks > 0 {
                canvas.put(x + 3 + view.title.count + 1, 0, "\(asks)", .agent, bold: true)
            }
            x += tab.count + 1
        }
        let pill: TermSpan
        switch state.mode {
        case .guarding: pill = TermSpan(" ● guarding ", .ok, bold: true, fill: .ok)
        case .watching: pill = TermSpan(" ◐ watching ", .watch, bold: true, fill: .watch)
        }
        let right = [pill, TermSpan("  " + clock(state.now, calendar: calendar, seconds: false), .soft)]
        canvas.segs(width - length(right) - 2, 0, right)
    }

    static func hints(_ canvas: inout TermCanvas, _ state: TermState, row: Int) {
        var keys: [(String, String)]
        let asking = !state.asks.isEmpty
        switch state.navigation.current {
        case .glance:
            if asking {
                keys = [("a", "allow"), ("d", "deny"), ("3", "all requests")]
            } else if state.mode == .guarding {
                keys = [("space", "stream"), ("3", "needs you")]
            } else {
                keys = [("space", "stream"), ("G", "start guarding")]
            }
        case .stream:
            keys = [("↑↓", "move"), ("⏎", "why"), ("f", state.wouldStopsOnly ? "everything" : "would-stops only"), ("esc", "back")]
        case .needsYou:
            keys = asking ? [("a", "allow"), ("d", "deny"), ("esc", "back")] : [("esc", "back")]
        }
        keys.append(("?", "keys"))
        let total = keys.reduce(0) { $0 + $1.0.count + $1.1.count + 4 } - 3
        var x = max(2, (canvas.width - total) / 2)
        for (key, label) in keys {
            x = canvas.put(x, row, key, .soft, bold: true)
            x = canvas.put(x + 1, row, label, .ghost) + 3
        }
    }

    // MARK: - Glance

    static func glance(_ canvas: inout TermCanvas, _ state: TermState, top: Int, room: Int) {
        let width = canvas.width
        let center = width / 2
        var y = top + max(0, (room - 18) / 2)
        let working = state.agentsWorking
        if working > 0 {
            canvas.center(center, y, [TermSpan("●", .ok), TermSpan("  \(working) \(working == 1 ? "agent" : "agents") working", .mute)])
        } else {
            canvas.center(center, y, [TermSpan("●", .ghost), TermSpan("  no agents working", .mute)])
        }
        y += 2
        let sentence = self.sentence(state, width: width)
        canvas.center(center, y, sentence.head)
        y += 1
        canvas.center(center, y, sentence.sub)
        y += 3
        y = river(&canvas, state, row: y)
        if let latest = state.latest {
            let ran = latest.event == .ran
            canvas.center(center, y, [
                TermSpan(latest.agent, .agent), TermSpan("   ", .ghost),
                TermSpan(fit(latest.display, max(20, width - 30)), ran ? .soft : .fg, bold: !ran),
                TermSpan("   ", .ghost), glyph(latest.event, ranMark: "✓"),
            ])
        }
        y += 2
        let cardWidth = min(72, width - 6)
        let x = (width - cardWidth) / 2
        if let ask = state.asks.first {
            needCard(&canvas, x: x, y: min(y, top + room - 7), width: cardWidth, ask: ask, total: state.asks.count, now: state.now)
        } else if state.mode == .watching, state.message == nil, state.recentRisk(within: TermState.recentRiskWindow) == nil {
            let week = state.wouldStopThisWeek
            let saved = week == 0
                ? "nothing rv would have stopped this week"
                : "rv would have stopped \(format(week)) \(week == 1 ? "command" : "commands") this week"
            canvas.box(x, y, cardWidth, 4)
            canvas.segs(x + 3, y + 1, [
                TermSpan("◐ ", .watch, bold: true), TermSpan("Ready to guard", .fg, bold: true), TermSpan("   " + saved, .soft),
            ], limit: cardWidth - 6)
            canvas.segs(x + 3, y + 2, [TermSpan("G", .go, bold: true), TermSpan(" start guarding, with Touch ID", .mute)], limit: cardWidth - 6)
        }
    }

    /// Glance's headline and the line under it.
    static func sentence(_ state: TermState, width: Int) -> (head: [TermSpan], sub: [TermSpan]) {
        if let ask = state.asks.first {
            let count = state.asks.count
            return (
                [TermSpan("⏺ ", .agent, bold: true), TermSpan(ask.agent, .agent, bold: true),
                 TermSpan(" is asking you something.", .fg, bold: true)],
                [TermSpan("answer where it asked, or press 3 to see " + (count > 1 ? "all \(count)" : "it") + " in Needs you", .mute)]
            )
        }
        let risk = state.recentRisk(within: TermState.recentRiskWindow)
        if let message = state.message, risk.map({ $0.time <= message.at }) ?? true {
            return ([TermSpan(message.text + ".", .fg, bold: true)], [TermSpan("back to work", .mute)])
        }
        if let risk {
            let head: [TermSpan] = risk.event == .stopped
                ? [TermSpan("✕ ", .stop, bold: true), TermSpan("rv stopped \(risk.agent).", .fg, bold: true)]
                : [TermSpan("◐ ", .watch, bold: true),
                   TermSpan("\(risk.agent) tried something risky. rv let it run and noted it.", .fg, bold: true)]
            return (head, [TermSpan(fit(risk.display, width - 24), .soft), TermSpan("   ⏎ why", .go)])
        }
        let outcome = state.mode == .guarding
            ? "\(format(state.tally.stoppedToday)) stopped"
            : "\(format(state.tally.watchedToday)) would have been stopped"
        var sub: [TermSpan]
        if let checked = state.checkedToday {
            sub = [TermSpan("\(format(checked)) \(checked == 1 ? "command" : "commands") checked today", .mute),
                   TermSpan("  ·  ", .ghost), TermSpan(outcome, .mute)]
        } else {
            sub = [TermSpan(outcome + " today", .mute)]
        }
        return ([TermSpan("Nothing needs you.", .fg, bold: true)], sub)
    }

    /// The last 30 minutes: would-stops and stops pinned on top, with what
    /// they were; how busy each 10 seconds was, in braille, under them.
    /// Returns the row after the axis and a blank.
    @discardableResult
    static func river(_ canvas: inout TermCanvas, _ state: TermState, row y: Int) -> Int {
        let width = canvas.width
        let margin = width < 96 ? 4 : 10
        let span = width - margin * 2
        let window = TermTally.riverWindow
        let marks = state.rows.filter { $0.event != .ran && state.now.timeIntervalSince($0.time) < window && $0.time <= state.now }
        var used: [Range<Int>] = []
        let placed = marks.map { row -> (row: TermRow, x: Int) in
            let age = state.now.timeIntervalSince(row.time)
            return (row, margin + span - 1 - Int((age / window * Double(span - 1)).rounded()))
        }
        for mark in placed {
            canvas.put(mark.x, y, mark.row.event == .stopped ? "✕" : "◐", mark.row.event == .stopped ? .stop : .watch, bold: true)
            used.append(mark.x..<(mark.x + 1))
        }
        for mark in placed.reversed() {
            let label = fit(mark.row.display, width < 96 ? 16 : 26)
            var x = mark.x + 2
            if x + label.count > margin + span { x = mark.x - 1 - label.count }
            let clash = used.contains { x < $0.upperBound + 1 && x + label.count > $0.lowerBound - 1 }
            if x >= margin, !clash {
                canvas.put(x, y, label, .mute)
                used.append(x..<(x + label.count))
            }
        }
        braille(&canvas, x: margin, y: y + 1, width: span, height: 2, values: activity(state))
        canvas.put(margin, y + 3, "30 min ago", .ghost)
        canvas.put(margin + span - 5, y + 3, "now", .ghost)
        canvas.put(margin + span - 1, y + 3, "●", .ok)
        return y + 5
    }

    /// Commands per 10 seconds over the river's 30 minutes, oldest first,
    /// each at least 1 so a quiet stretch still draws a baseline.
    static func activity(_ state: TermState) -> [Int] {
        let buckets = 180
        let window = TermTally.riverWindow
        var counts = Array(repeating: 1, count: buckets)
        for row in state.rows {
            let age = state.now.timeIntervalSince(row.time)
            guard age >= 0, age < window else { continue }
            counts[buckets - 1 - min(buckets - 1, Int(age / window * Double(buckets)))] += 1
        }
        return counts
    }

    /// A bar chart in braille dots, two columns of dots per cell, as the
    /// mock's `braille` draws it.
    static func braille(_ canvas: inout TermCanvas, x: Int, y: Int, width: Int, height: Int, values: [Int]) {
        guard width > 0, height > 0, !values.isEmpty else { return }
        let dots = height * 4
        let top = max(6, values.max() ?? 1)
        let columns = width * 2
        let left: [UInt32] = [1, 2, 4, 64]
        let right: [UInt32] = [8, 16, 32, 128]
        for cell in 0..<width {
            let heights = (0..<2).map { k -> Int in
                let value = values[min(values.count - 1, (cell * 2 + k) * values.count / columns)]
                return Int((Double(value) / Double(top) * Double(dots)).rounded())
            }
            for row in 0..<height {
                var bits: UInt32 = 0
                let base = (height - 1 - row) * 4
                for k in 0..<2 {
                    let filled = heights[k] - base
                    for d in 0..<4 where filled > d {
                        bits |= (k == 0 ? left : right)[3 - d]
                    }
                }
                if bits != 0, let scalar = Unicode.Scalar(0x2800 + bits) {
                    canvas.put(x + cell, y + row, String(Character(scalar)), .mute)
                }
            }
        }
    }

    // MARK: - Stream

    static func stream(_ canvas: inout TermCanvas, _ state: TermState, top: Int, room: Int, calendar: Calendar) {
        let width = canvas.width
        let agentsWidth = width >= TermState.agentsColumnWidth ? 22 : 0
        let inspectorWidth = width >= TermState.inspectorWidth ? 38 : 0
        let x = 2 + (agentsWidth > 0 ? agentsWidth + 3 : 0)
        let span = width - x - 2 - (inspectorWidth > 0 ? inspectorWidth + 2 : 0)
        let focusOnAgents = agentsWidth > 0 && state.streamFocus == .agents
        if agentsWidth > 0 {
            canvas.put(2, top, "Agents", focusOnAgents ? .fg : .mute, bold: focusOnAgents)
            var y = top + 2
            let items: [(name: String?, label: String, sub: String, ink: TermInk)] =
                [(nil, "All agents", "\(state.agentsWorking) working", .fg)]
                + state.agents.map { ($0.name, $0.name, $0.project ?? "", .agent) }
            for item in items where y + 1 < top + room {
                let on = state.agentFilter == item.name
                let fill: TermFill? = on ? (focusOnAgents ? .sel : .panel) : nil
                if on { canvas.fill(1, y, agentsWidth + 1, 2, fill) }
                canvas.put(3, y, fit(item.label, agentsWidth - 3), on ? .fg : item.ink, bold: true)
                canvas.put(3, y + 1, fit(item.sub, agentsWidth - 3), .mute)
                y += 3
            }
        }
        let title = state.agentFilter ?? "All agents"
        canvas.segs(x, top, [
            TermSpan(title, state.agentFilter == nil ? .fg : .agent, bold: true), TermSpan("  live ", .mute), TermSpan("●", .ok),
        ])
        let chips = [("everything", !state.wouldStopsOnly), ("◐ would stop", state.wouldStopsOnly)]
        var chipX = x + span - chips.reduce(0) { $0 + $1.0.count + 3 } + 1
        for (label, on) in chips {
            let chip = " " + label + " "
            canvas.put(chipX, top, chip, on ? .fg : .ghost, bold: on, fill: on ? .sel : nil)
            chipX += chip.count + 1
        }
        let list = state.streamRows
        guard !list.isEmpty else {
            canvas.put(x, top + 2, state.wouldStopsOnly ? "Nothing would have been stopped in this list." : "No commands yet.", .mute)
            if state.checkedToday == nil {
                canvas.put(x, top + 3, fit("This rvd keeps no decision log yet, so only would-stops and stops show here.", span), .ghost)
            }
            return
        }
        let selected = state.selectedIndex
        let visible = room - 2
        let start = max(0, selected - visible + 3)
        for offset in 0..<visible where start + offset < list.count {
            let row = list[start + offset]
            let y = top + 2 + offset
            if start + offset == selected {
                canvas.fill(x - 1, y, span + 2, 1, focusOnAgents ? .panel : .sel)
            }
            var column = canvas.put(x, y, clock(row.time, calendar: calendar, seconds: false), .ghost) + 2
            column = canvas.put(column, y, glyph(row.event, ranMark: "·").text, glyph(row.event, ranMark: "·").ink, bold: row.event != .ran) + 2
            if state.agentFilter == nil {
                column = canvas.put(column, y, pad(fit(row.agent, 9), 9), .agent)
            }
            let ran = row.event == .ran
            canvas.put(column, y, fit(row.display, x + span - column), row.isLogged ? (ran ? .soft : .fg) : .mute, bold: !ran && row.isLogged)
        }
        if inspectorWidth > 0, let row = list[safe: selected] {
            inspector(&canvas, row, x: width - inspectorWidth - 1, y: top - 1, width: inspectorWidth + 1, height: room + 2,
                      closable: false, calendar: calendar)
        }
    }

    /// Why one row ran or stopped: the side panel on a wide Stream, and
    /// the `⏎` sheet on a narrow one.
    static func inspector(
        _ canvas: inout TermCanvas, _ row: TermRow, x: Int, y: Int, width: Int, height: Int, closable: Bool, calendar: Calendar
    ) {
        canvas.fill(x, y, width, height, .panel)
        let inner = width - 4
        let left = x + 2
        var line = y + 1
        let head: TermSpan
        switch row.event {
        case .stopped: head = TermSpan("✕  Stopped", .stop, bold: true)
        case .wouldStop: head = TermSpan("◐  Would stop", .watch, bold: true)
        case .ran: head = TermSpan("✓  Ran", .ok, bold: true)
        }
        canvas.segs(left, line, [head])
        canvas.put(left + inner - 8, line, clock(row.time, calendar: calendar, seconds: true), .ghost)
        line += 2
        canvas.segs(left, line, [TermSpan(row.agent, .agent, bold: true), TermSpan(row.project.map { "  " + $0 } ?? "", .mute)], limit: inner)
        line += 1
        if row.isLogged {
            for text in wrap(row.text, inner).prefix(3) {
                canvas.put(left, line, text, .fg, bold: true)
                line += 1
            }
        } else {
            for text in wrap(TermRow.notLoggedReason, inner).prefix(3) {
                canvas.put(left, line, text, .mute)
                line += 1
            }
        }
        line += 1
        var facts: [(String, String)] = []
        switch row.event {
        case .ran:
            facts.append(("Why it ran", row.rule ?? "no rule matched"))
        case .wouldStop, .stopped:
            facts.append(("Why", row.rule ?? "a rule matched"))
            if let cwd = row.cwd { facts.append(("Where", cwd)) }
            if row.event == .wouldStop { facts.append(("Guarding would", "stop it and tell \(row.agent) why")) }
        }
        for (label, value) in facts {
            guard line < y + height - 3 else { break }
            canvas.put(left, line, label, .ghost)
            line += 1
            for text in wrap(value, inner).prefix(2) {
                canvas.put(left, line, text, .soft)
                line += 1
            }
            line += 1
        }
        if closable {
            canvas.segs(left, y + height - 2, [TermSpan("esc", .go, bold: true), TermSpan(" close", .mute)], limit: inner)
        }
    }

    // MARK: - Needs you

    static func needsYou(_ canvas: inout TermCanvas, _ state: TermState, top: Int, room: Int) {
        let width = canvas.width
        let center = width / 2
        let cardWidth = min(72, width - 6)
        let cardHeight = 7
        let x = (width - cardWidth) / 2
        let y = top + max(2, (room - cardHeight) / 2)
        if let message = state.message {
            canvas.center(center, max(top, y - 3), [TermSpan(message.text, .soft)])
        }
        let asks = state.asks.sorted { $0.since < $1.since }
        guard let first = asks.first else {
            canvas.center(center, y + 1, [TermSpan("✓  ", .ok, bold: true), TermSpan("Nothing needs you.", .fg, bold: true)])
            canvas.center(center, y + 3, [TermSpan("Agents keep working while they wait.", .mute)])
            return
        }
        if asks.count > 1 {
            for k in stride(from: min(2, asks.count - 1), through: 1, by: -1) {
                canvas.put(x + k * 3, y - k, "╭" + String(repeating: "─", count: max(0, cardWidth - 2 - k * 6)) + "╮", .hair)
            }
        }
        needCard(&canvas, x: x, y: y, width: cardWidth, ask: first, total: asks.count, now: state.now)
    }

    static func needCard(_ canvas: inout TermCanvas, x: Int, y: Int, width: Int, ask: TermAsk, total: Int, now: Date) {
        let ink: TermInk = ask.kind == "MCP tool" ? .go : .agent
        canvas.box(x, y, width, 7, ink, fill: .panel)
        let inner = width - 6
        let left = x + 3
        canvas.segs(left, y + 1, [TermSpan(ask.kind.uppercased(), .ghost), TermSpan(total > 1 ? "   1 of \(total)" : "", .ghost)])
        canvas.segs(left, y + 2, [
            TermSpan("⏺ ", ink), TermSpan(ask.agent, ink, bold: true),
            TermSpan(" " + fit(ask.summary, inner - ask.agent.count - 3), .fg, bold: true),
        ])
        let detail = [ask.detail, "asked " + ago(ask.since, now)].compactMap { $0 }.joined(separator: " · ")
        canvas.put(left, y + 3, fit(detail, inner), .mute)
        canvas.segs(left, y + 5, [
            TermSpan("a", .go, bold: true), TermSpan("  Allow once", .fg), TermSpan("      ", .ghost),
            TermSpan("d", .go, bold: true), TermSpan("  Deny", .fg),
        ], limit: inner)
    }

    // MARK: - Over the view

    static func toast(_ canvas: inout TermCanvas, _ row: TermRow, bottom: Int) {
        let width = min(46, canvas.width - 4)
        let x = canvas.width - width - 2
        let y = bottom - 1 - 4
        let ink: TermInk = row.event == .stopped ? .stop : .watch
        canvas.box(x, y, width, 4, ink, fill: .panel)
        canvas.segs(x + 2, y + 1, [
            TermSpan(row.event == .stopped ? "✕ Stopped" : "◐ Would stop", ink, bold: true), TermSpan(" · " + row.agent, .agent),
        ], limit: width - 4)
        canvas.segs(x + 2, y + 2, [TermSpan(fit(row.display, width - 14), .fg), TermSpan("   space why", .go)], limit: width - 4)
    }

    static let keyRows: [(String, String)] = [
        ("1  2  3", "Glance, Stream, Needs you"),
        ("space", "glance ⇄ stream"),
        ("a  d", "allow, deny the request"),
        ("↑↓  ⏎", "move, why"),
        ("f", "would-stops only"),
        ("G  W", "start guarding, back to watching"),
        ("esc", "back"),
        ("q", "quit"),
    ]

    static func keysSheet(_ canvas: inout TermCanvas, bottom: Int) {
        let width = min(50, canvas.width - 4)
        let height = keyRows.count + 4
        let x = max(1, (canvas.width - width) / 2)
        let y = max(1, (bottom - height) / 2)
        canvas.box(x, y, width, height, fill: .panel)
        canvas.put(x + 3, y + 1, "Keys", .fg, bold: true)
        for (index, row) in keyRows.enumerated() {
            canvas.put(x + 3, y + 3 + index, pad(row.0, 9), .go, bold: true)
            canvas.put(x + 13, y + 3 + index, row.1, .soft)
        }
    }

    static func whySheet(_ canvas: inout TermCanvas, _ row: TermRow, bottom: Int, calendar: Calendar) {
        let width = min(64, canvas.width - 4)
        let height = bottom - 4
        let x = max(1, (canvas.width - width) / 2)
        let y = max(1, (bottom - height) / 2)
        let ink: TermInk
        switch row.event {
        case .ran: ink = .hair
        case .wouldStop: ink = .watch
        case .stopped: ink = .stop
        }
        canvas.box(x, y, width, height, ink, fill: .panel)
        inspector(&canvas, row, x: x + 1, y: y + 1, width: width - 2, height: height - 2, closable: true, calendar: calendar)
    }

    // MARK: - Pieces

    static func glyph(_ event: TermEvent, ranMark: String) -> TermSpan {
        switch event {
        case .ran: TermSpan(ranMark, .ghost)
        case .wouldStop: TermSpan("◐", .watch, bold: true)
        case .stopped: TermSpan("✕", .stop, bold: true)
        }
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

    /// 1284 as "1,284".
    static func format(_ number: Int) -> String {
        let digits = String(abs(number))
        var out = ""
        for (index, char) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(char)
        }
        return number < 0 ? "-" + out : out
    }

    static func length(_ spans: [TermSpan]) -> Int { spans.reduce(0) { $0 + $1.text.count } }

    /// `text` cut to `width` characters, ending in "…" when cut.
    static func fit(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        guard text.count > width else { return text }
        return String(text.prefix(max(0, width - 1))) + "…"
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Words onto lines of at most `width` characters; a word longer than
    /// a line is cut.
    static func wrap(_ text: String, _ width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let word = String(word)
            if line.isEmpty {
                line = fit(word, width)
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = fit(word, width)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}

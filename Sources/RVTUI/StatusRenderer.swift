import RVDomain
import RVPresentation
import RVTheme

/// Bare `rv` on a terminal. Colour marks a decision or rvd's pulse;
/// everything else is plain or silver. One idea per line, the next command
/// last.
public struct StatusRenderer: FrameRenderer {
    static let pad = "  "
    /// Label column (`secrets` and three spaces).
    static let labelWidth = 10
    /// The header's version sits flush with this column.
    static let headerWidth = 56

    public init() {}

    public func render(_ model: StatusViewModel, palette: Palette) -> [String] {
        [
            "",
            header(model, palette: palette),
            "",
            row("today", today(model, palette: palette), palette: palette),
            row("last", last(model, palette: palette), palette: palette),
            row("secrets", secrets(model, palette: palette), palette: palette),
            "",
            next(model.next, palette: palette),
        ].map { $0.isEmpty ? $0 : Self.pad + $0 }
    }

    // MARK: - Lines

    private func header(_ model: StatusViewModel, palette: Palette) -> String {
        let rv = CommandVocabulary.Glyph.rv
        let lead = [(rv.rawValue, palette.heading), (" " + rv.word, palette.fact), ("   ", "")]
            + coverage(model.coverage, palette: palette)
        let plainWidth = lead.reduce(0) { $0 + $1.0.count }
        let gap = String(repeating: " ", count: max(2, Self.headerWidth - plainWidth - model.version.count))
        return painted(lead, palette: palette) + gap + paint(model.version, slot: palette.silver, reset: palette.reset)
    }

    private func coverage(_ coverage: StatusViewModel.Coverage, palette: Palette) -> [(String, String)] {
        let guarding = CommandVocabulary.PlannedWord.guarding
        let watching = CommandVocabulary.PlannedWord.watching
        switch coverage {
        case .agents(let g, 0):
            return [("●", palette.allow), (" \(guarding) \(agents(g))", "")]
        case .agents(0, let w):
            return [(CommandVocabulary.Glyph.watched.rawValue, palette.mark), (" \(watching) \(agents(w))", "")]
        case .agents(let g, let w):
            return [
                ("●", palette.allow), (" \(guarding) \(agents(g))", ""), ("  ·  ", palette.silver),
                (CommandVocabulary.Glyph.watched.rawValue, palette.mark), (" \(watching) \(w)", ""),
            ]
        case .noAgents:
            return [("●", palette.allow), (" running, no agents connected", "")]
        case .serviceDown:
            return [(CommandVocabulary.Glyph.stopped.rawValue, palette.deny), (" rvd is not running", "")]
        case .notInstalled:
            return [("○", palette.silver), (" not set up", "")]
        }
    }

    private func today(_ model: StatusViewModel, palette: Palette) -> String {
        guard model.eventsRecorded else {
            return paint("not counted, rv keeps no log", slot: palette.silver, reset: palette.reset)
        }
        var parts: [String] = []
        if let checked = model.commandsChecked {
            parts.append("\(checked) commands checked")
        }
        let wouldStop = "\(model.wouldStopToday) \(CommandVocabulary.Glyph.watched.eventWord ?? "")"
        parts.append(model.wouldStopToday > 0 ? paint(wouldStop, slot: palette.mark, reset: palette.reset) : wouldStop)
        let stopped = "\(model.stoppedToday) \(CommandVocabulary.Glyph.stopped.eventWord ?? "")"
        parts.append(model.stoppedToday > 0 ? paint(stopped, slot: palette.deny, reset: palette.reset) : stopped)
        return parts.joined(separator: dot(palette))
    }

    private func last(_ model: StatusViewModel, palette: Palette) -> String {
        guard let last = model.last else {
            let text = model.eventsRecorded ? "nothing stopped this week" : "not kept"
            return paint(text, slot: palette.silver, reset: palette.reset)
        }
        let ink = last.verdict == .stopped ? palette.deny : palette.mark
        return paint(padRight(last.age, to: 4), slot: palette.silver, reset: palette.reset)
            + padRight(last.agent, to: 9)
            + last.what + "   "
            + paint(last.verdict.label, slot: ink, reset: palette.reset)
    }

    private func secrets(_ model: StatusViewModel, palette: Palette) -> String {
        let console = model.consoleConnected
            ? "console " + paint("●", slot: palette.allow, reset: palette.reset) + " connected"
            : "console not connected"
        return "\(model.secrets) locked" + dot(palette) + console
    }

    private func next(_ next: StatusViewModel.Next, palette: Palette) -> String {
        paint("\(CommandVocabulary.Glyph.next.rawValue) \(next.command)", slot: palette.heading, reset: palette.reset)
            + "   " + paint(next.hint, slot: palette.silver, reset: palette.reset)
    }

    // MARK: - Parts

    private func row(_ label: String, _ body: String, palette: Palette) -> String {
        paint(padRight(label, to: Self.labelWidth), slot: palette.silver, reset: palette.reset) + body
    }

    private func dot(_ palette: Palette) -> String {
        "  " + paint("·", slot: palette.silver, reset: palette.reset) + "  "
    }

    private func agents(_ count: Int) -> String {
        count == 1 ? "1 agent" : "\(count) agents"
    }

    private func painted(_ parts: [(String, String)], palette: Palette) -> String {
        parts.map { paint($0.0, slot: $0.1, reset: palette.reset) }.joined()
    }
}

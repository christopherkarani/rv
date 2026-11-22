import RVDomain
import RVPresentation
import RVTheme

/// `rv log` at a terminal width.
public struct LogFrame: Equatable, Sendable {
    public var model: LogViewModel
    /// Terminal columns; 80 when stdout is not a terminal.
    public var columns: Int

    public init(model: LogViewModel, columns: Int = 80) {
        self.model = model
        self.columns = columns
    }
}

/// Paints `rv log`: a `◆` heading with the count, one row per decision in
/// fixed columns (time, agent, verdict, rule, command, code), a muted day
/// line above rows from an earlier day, one summary line, then the next
/// command. Columns are as wide as their widest cell;
/// the command column takes what is left of the width and ends in `…`
/// when cut. Without color the glyphs and words carry the meaning.
public struct LogRenderer: FrameRenderer {
    public init() {}

    static let indent = "  "
    static let gap = "  "
    /// The command column keeps at least this much before the rule is cut.
    static let minimumCommand = 8

    public func render(_ frame: LogFrame, palette: Palette) -> [String] {
        let model = frame.model
        let widths = Self.widths(model.rows, columns: frame.columns)
        var lines = [""]
        lines.append(heading(model, width: widths.total, palette: palette))
        lines.append("")
        if let empty = model.emptyMessage {
            lines.append(Self.indent + empty)
        } else {
            var day: String?
            for row in model.rows {
                if let label = row.dayLabel, label != day {
                    day = label
                    lines.append(Self.indent + paint(label, slot: palette.muted, reset: palette.reset))
                }
                lines.append(self.row(for: row, widths: widths, palette: palette))
            }
        }
        if model.ledgerOff == false, model.rows.isEmpty == false || model.judgeNotesHidden > 0 {
            lines.append("")
            lines.append(Self.indent + paint(model.summary, slot: palette.muted, reset: palette.reset))
        }
        if let next = model.next {
            lines.append("")
            lines.append(
                Self.indent
                    + paint(CommandVocabulary.Glyph.next.rawValue + " " + next.command, slot: palette.heading, reset: palette.reset)
                    + "   " + paint(next.why, slot: palette.muted, reset: palette.reset)
            )
        }
        return lines
    }

    private func heading(_ model: LogViewModel, width: Int, palette: Palette) -> String {
        let left = CommandVocabulary.Glyph.rv.rawValue + " " + model.spanLabel
        let right = model.rows.isEmpty ? "" : model.countLabel
        let room = max(2, width - Self.indent.count - left.count - right.count)
        let glyph = paint(CommandVocabulary.Glyph.rv.rawValue, slot: palette.heading, reset: palette.reset)
        return Self.indent + glyph + " " + paint(model.spanLabel, slot: palette.fact, reset: palette.reset)
            + (right.isEmpty ? "" : String(repeating: " ", count: room) + paint(right, slot: palette.muted, reset: palette.reset))
    }

    private func row(for row: LogRow, widths: Widths, palette: Palette) -> String {
        let verdictSlot = row.verdict == .stopped ? palette.deny : palette.mark
        let commandSlot = row.verdict == .stopped ? palette.fact : ""
        let cells: [(String, Int, String)] = [
            (row.timeLabel, widths.time, palette.muted),
            (DisplayedText.field(row.agent), widths.agent, ""),
            (row.verdict.label, widths.verdict, verdictSlot),
            (DisplayedText.field(row.rule), widths.rule, palette.silver),
        ]
        let padded = cells.map { text, width, slot in
            paint(padRight(Self.clip(text, to: width), to: width), slot: slot, reset: palette.reset)
        } + [paint(padRight(Self.command(row, to: widths.command), to: widths.command), slot: commandSlot, reset: palette.reset)]
        return Self.indent + (padded + [paint(row.code, slot: palette.muted, reset: palette.reset)])
            .joined(separator: Self.gap)
    }

    struct Widths: Equatable {
        var time: Int
        var agent: Int
        var verdict: Int
        var rule: Int
        var command: Int
        var code: Int

        /// The row width, indent included.
        var total: Int {
            LogRenderer.indent.count + time + agent + verdict + rule + command + code + LogRenderer.gap.count * 5
        }
    }

    /// Column widths for `rows` in `columns`: every column but rule and
    /// command as wide as its widest cell; the rule whole unless the
    /// command would drop below `minimumCommand`; the command the rest.
    static func widths(_ rows: [LogRow], columns: Int) -> Widths {
        func widest(_ cell: (LogRow) -> String) -> Int {
            rows.map { cell($0).count }.max() ?? 0
        }
        var widths = Widths(
            time: widest(\.timeLabel),
            agent: widest { DisplayedText.field($0.agent) },
            verdict: widest(\.verdict.label),
            rule: 0,
            command: 0,
            code: widest(\.code)
        )
        let rule = widest { DisplayedText.field($0.rule) }
        let command = widest { DisplayedText.field($0.command) }
        let room = max(2, columns - widths.total)
        widths.rule = max(1, min(rule, room - min(command, minimumCommand)))
        widths.command = max(1, min(command, room - widths.rule))
        return widths
    }

    /// The command cell in `width`: a shell command keeps its start
    /// (`git reset --hard orig…`); a file keeps the end of its path, where
    /// the name is (`Read …/id_ed25519`), and drops the tool too when the
    /// cell is narrow (`…d_ed25519`).
    static func command(_ row: LogRow, to width: Int) -> String {
        let command = DisplayedText.field(row.command)
        let tool = DisplayedText.field(row.tool)
        guard command.count > width, width > 1, row.target.isEmpty == false, command.hasPrefix(tool + " ") else {
            return clip(command, to: width)
        }
        let path = command.dropFirst(tool.count + 1)
        let lead = width >= tool.count + 2 + minimumPathTail ? tool + " …" : "…"
        return lead + String(path.suffix(width - lead.count))
    }

    /// Path characters a cut file cell keeps before it also drops the tool.
    static let minimumPathTail = 10

    /// `text`, cut to `width` characters with `…` as the last one.
    static func clip(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 1 else { return String(text.prefix(width)) }
        return String(text.prefix(width - 1)) + "…"
    }
}

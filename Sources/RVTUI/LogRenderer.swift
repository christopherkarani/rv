import RVDomain
import RVPresentation
import RVTheme

/// `rv log` at a terminal width.
public struct LogFrame: Equatable, Sendable {
    public var model: LogViewModel
    /// Terminal columns, or nil for no limit: piped output keeps every
    /// cell whole, so `rv log | grep` sees full commands.
    public var columns: Int?

    public init(model: LogViewModel, columns: Int? = 80) {
        self.model = model
        self.columns = columns
    }
}

/// Paints `rv log`: a `◆` heading with the count, one row per decision in
/// fixed columns (time, agent, verdict, rule, command, code), a day line
/// above rows from an earlier day, one summary line, then the next
/// command. Columns are as wide as their widest cell, in terminal columns
/// (`TerminalWidth`). When a row is too wide the command is cut first (to
/// `minimumCommand`), then the rule (to `minimumRule`), then the code
/// column goes, then the command is cut again; a cut cell ends in `…`. Lines of
/// prose wrap. Without color the glyphs and words carry the meaning.
///
/// Only the glyphs carry ink, as in v5c's rv term frame, through
/// `Palette`: `✕` red (`deny`), `◐` amber (`mark`), `→` blue (`trace`),
/// `◆` in the heading ink. Every word stays plain. `colorOffPalette`
/// (piped, `NO_COLOR`, `TERM=dumb`) paints nothing.
public struct LogRenderer: FrameRenderer {
    public init() {}

    static let indent = "  "
    static let gap = "  "
    /// The command keeps this much while anything else can give.
    static let minimumCommand = 18
    /// The rule keeps this much: enough for a pack and the start of a name
    /// (`core.git:re…`).
    static let minimumRule = 12

    public func render(_ frame: LogFrame, palette: Palette) -> [String] {
        let model = frame.model
        let widths = Self.widths(model.rows, columns: frame.columns)
        let proseWidth = frame.columns.map { max(1, $0 - Self.indent.count) }
        func prose(_ text: String) -> [String] {
            Self.wrapped(text, width: proseWidth).map { Self.indent + $0 }
        }
        var lines = [""]
        lines.append(heading(model, width: frame.columns.map { min($0, widths.total) } ?? widths.total, palette: palette))
        lines.append("")
        if let empty = model.emptyMessage {
            lines += prose(empty)
        } else {
            var day: String?
            for row in model.rows {
                if let label = row.dayLabel, label != day {
                    day = label
                    lines.append(Self.indent + label)
                }
                lines.append(self.row(for: row, widths: widths, palette: palette))
            }
        }
        if model.ledgerOff == false, model.rows.isEmpty == false || model.judgeNotesHidden > 0 {
            lines.append("")
            lines += Self.summaryLines(model.summaryParts, width: proseWidth).map { Self.indent + $0 }
        }
        if let skipped = model.skippedNote {
            lines += prose(skipped)
        }
        if let next = model.next {
            lines.append("")
            // v5c: the → glyph blue; the command and the reason plain.
            let command = CommandVocabulary.Glyph.next.rawValue + " " + next.command
            let painted = Self.indent
                + paint(CommandVocabulary.Glyph.next.rawValue, slot: palette.trace, reset: palette.reset) + " "
                + next.command
            let oneLine = Self.indent.count + TerminalWidth.of(command) + 3 + TerminalWidth.of(next.why)
            if let columns = frame.columns, oneLine > columns {
                lines.append(painted)
                lines.append(Self.indent + "  " + next.why)
            } else {
                lines.append(painted + "   " + next.why)
            }
        }
        return lines
    }

    private func heading(_ model: LogViewModel, width: Int, palette: Palette) -> String {
        let left = CommandVocabulary.Glyph.rv.rawValue + " " + model.spanLabel
        let right = model.rows.isEmpty ? "" : model.countLabel
        let room = max(2, width - Self.indent.count - TerminalWidth.of(left) - TerminalWidth.of(right))
        let glyph = paint(CommandVocabulary.Glyph.rv.rawValue, slot: palette.heading, reset: palette.reset)
        return Self.indent + glyph + " " + model.spanLabel
            + (right.isEmpty ? "" : String(repeating: " ", count: room) + right)
    }

    private func row(for row: LogRow, widths: Widths, palette: Palette) -> String {
        // Only the verdict's glyph carries ink; its word and every other
        // cell stay plain.
        let glyph = row.verdict.glyph.rawValue
        let ink = row.verdict == .stopped ? palette.deny : palette.mark
        func cell(_ text: String, _ width: Int, padded: Bool = true) -> String {
            let shown = TerminalWidth.clip(text, to: width)
            return padded ? TerminalWidth.pad(shown, to: width) : shown
        }
        let verdict = cell(row.verdict.label, widths.verdict)
        var cells = [
            cell(row.timeLabel, widths.time),
            cell(DisplayedText.field(row.agent), widths.agent),
            verdict.hasPrefix(glyph)
                ? paint(glyph, slot: ink, reset: palette.reset) + verdict.dropFirst(glyph.count)
                : verdict,
            cell(DisplayedText.field(row.rule), widths.rule),
        ]
        let command = Self.command(row, to: widths.command)
        if widths.code > 0 {
            cells.append(cell(command, widths.command))
            cells.append(DisplayedText.field(row.code ?? ""))
        } else {
            cells.append(cell(command, widths.command, padded: false))
        }
        let line = Self.indent + cells.joined(separator: Self.gap)
        // A row with no code ends in its padding.
        return row.code == nil ? String(line.reversed().drop(while: { $0 == " " }).reversed()) : line
    }

    struct Widths: Equatable {
        var time: Int
        var agent: Int
        var verdict: Int
        var rule: Int
        var command: Int
        /// 0 when the code column was dropped for room.
        var code: Int

        /// The row width, indent included.
        var total: Int {
            let columns = code > 0 ? 6 : 5
            return LogRenderer.indent.count + time + agent + verdict + rule + command + code
                + LogRenderer.gap.count * (columns - 1)
        }
    }

    /// Column widths for `rows` in `columns` (nil: every cell whole).
    static func widths(_ rows: [LogRow], columns: Int?) -> Widths {
        func widest(_ cell: (LogRow) -> String) -> Int {
            rows.map { TerminalWidth.of(cell($0)) }.max() ?? 0
        }
        let rule = widest { DisplayedText.field($0.rule) }
        let command = widest { DisplayedText.field($0.command) }
        var widths = Widths(
            time: widest(\.timeLabel),
            agent: widest { DisplayedText.field($0.agent) },
            verdict: widest(\.verdict.label),
            rule: rule,
            command: command,
            code: widest { DisplayedText.field($0.code ?? "") }
        )
        guard let columns else { return widths }
        func over() -> Int { widths.total - columns }
        // 1. The command gives, down to its minimum.
        widths.command = max(min(command, minimumCommand), command - max(0, over()))
        // 2. Then the rule, down to its minimum.
        if over() > 0 { widths.rule = max(min(rule, minimumRule), rule - over()) }
        // 3. Then the code column goes.
        if over() > 0 { widths.code = 0 }
        // 4. Then the command again, keeping one column.
        if over() > 0 { widths.command = max(1, widths.command - over()) }
        return widths
    }

    /// The command cell in `width`: a shell command keeps its start
    /// (`git reset --hard orig…`); a file keeps the end of its path, where
    /// the name is (`Read …/id_ed25519`), and drops the tool too when the
    /// cell is narrow (`…d_ed25519`).
    static func command(_ row: LogRow, to width: Int) -> String {
        let command = DisplayedText.field(row.command)
        let tool = DisplayedText.field(row.tool)
        guard TerminalWidth.of(command) > width, width > 1, row.target.isEmpty == false,
              row.recordedCommand == nil, command.hasPrefix(tool + " ")
        else {
            return TerminalWidth.clip(command, to: width)
        }
        let path = String(command.dropFirst(tool.count + 1))
        let lead = width >= TerminalWidth.of(tool) + 2 + minimumPathTail ? tool + " …" : "…"
        return lead + TerminalWidth.suffix(path, fitting: width - TerminalWidth.of(lead))
    }

    /// Path characters a cut file cell keeps before it also drops the tool.
    static let minimumPathTail = 10

    /// The summary parts joined with ` · `, broken between parts (and
    /// inside one only when it alone is too wide) to fit `width`.
    static func summaryLines(_ parts: [String], width: Int?) -> [String] {
        guard let width else { return [parts.joined(separator: " · ")] }
        var lines: [String] = []
        var line = ""
        for part in parts {
            let candidate = line.isEmpty ? part : line + " · " + part
            if TerminalWidth.of(candidate) <= width {
                line = candidate
                continue
            }
            if line.isEmpty == false { lines.append(line) }
            let pieces = TerminalWidth.wrap(part, width: width)
            lines += pieces.dropLast()
            line = pieces.last ?? ""
        }
        if line.isEmpty == false { lines.append(line) }
        return lines
    }

    static func wrapped(_ text: String, width: Int?) -> [String] {
        guard let width else { return [text] }
        return TerminalWidth.wrap(text, width: width)
    }
}

import RVPresentation
import RVTheme

public struct ScanPrettyRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: ScanViewModel, palette: Palette) -> [String] {
        var lines: [String] = []
        if model.rows.isEmpty {
            lines.append(paint("No deny findings.", slot: palette.muted, reset: palette.reset))
        } else {
            for row in model.rows {
                lines.append(findingLine(row, palette: palette))
            }
        }
        for warning in model.warnings {
            lines.append(
                paint("warning \(warning.code): \(warning.message)", slot: palette.mark, reset: palette.reset)
            )
        }
        lines.append(summaryLine(model, palette: palette))
        if model.setupNudgeRecommended {
            lines.append(
                paint(
                    "Some hosts are not wired. Run rv setup or rv doctor.",
                    slot: palette.silver,
                    reset: palette.reset
                )
            )
        }
        return lines
    }

    private func findingLine(_ row: ScanFindingRow, palette: Palette) -> String {
        let rule = paint(row.ruleLabel, slot: palette.deny, reset: palette.reset)
        let command = paint(row.commandDisplay, slot: palette.fact, reset: palette.reset)
        let countSuffix = row.count > 1 ? paint(" ×\(row.count)", slot: palette.muted, reset: palette.reset) : ""
        return "\(rule)  \(command)\(countSuffix)"
    }

    private func summaryLine(_ model: ScanViewModel, palette: Palette) -> String {
        let findingWord = model.rows.count == 1 ? "finding" : "findings"
        let text =
            "\(model.filesScanned) files scanned, \(model.eventsExtracted) events, \(model.rows.count) \(findingWord)"
        return paint(text, slot: palette.muted, reset: palette.reset)
    }
}

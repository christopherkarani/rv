import RVPresentation
import RVTheme

public struct TestRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: TestViewModel, palette: Palette) -> [String] {
        let width = model.columns
        var lines: [String] = []
        lines += commandBlock(model, palette: palette, width: width)
        lines.append("")
        let briefing = denyBriefing(model)
        if let pack = briefing.pack {
            lines += labeledField("Pack", pack, valueSlot: palette.heading, palette: palette, width: width)
        }
        if let pattern = briefing.pattern {
            lines += labeledField("Pattern", pattern, valueSlot: palette.mark, palette: palette, width: width)
        }
        if let reason = briefing.reason {
            lines += labeledField("Reason", reason, valueSlot: "", palette: palette, width: width)
        }
        if let explanation = model.explanation {
            lines += labeledExplanation(
                explanationLines(from: explanation),
                palette: palette,
                width: width
            )
        }
        if let source = model.source {
            lines += labeledField("Source", source, valueSlot: palette.muted, palette: palette, width: width)
        }
        lines.append(resultLine(model, palette: palette))
        return lines
    }
}

private func denyBriefing(_ model: TestViewModel) -> (pack: String?, pattern: String?, reason: String?) {
    if let deny = model.deny {
        return (deny.packID.rawValue, deny.ruleID.pattern, deny.packReason)
    }
    return (model.packDisplay, model.patternName, model.reason)
}

private let commandLabel = "Command: "
private let proseHang = "  "
private let bulletHang = "    "

private func commandBlock(_ model: TestViewModel, palette: Palette, width: Int) -> [String] {
    let budget = max(16, width - commandLabel.count)
    let window = windowCommand(
        model.command.rawValue,
        start: model.span?.start,
        end: model.span?.end,
        width: budget
    )
    var lines = [
        paint(commandLabel, slot: palette.muted, reset: palette.reset)
            + paintedCommand(
                window.display,
                start: window.start,
                end: window.end,
                palette: palette
            )
    ]
    if let start = window.start, let end = window.end {
        let caretCount = max(1, end - start)
        let caretPad = String(repeating: " ", count: commandLabel.count + start)
        let carets = String(repeating: "^", count: caretCount)
        lines.append(caretPad + paint(carets, slot: palette.deny, reset: palette.reset))
        if let label = model.matchedLabel {
            lines += matchedLabelLines(label: label, hang: caretPad, palette: palette, width: width)
        }
    }
    return lines
}

private func matchedLabelLines(label: String, hang: String, palette: Palette, width: Int) -> [String] {
    let connector = "└── "
    let body = "Matched: \(label)"
    let hung = hang + connector + body
    if hung.count <= width {
        return [
            hang
                + paint(connector, slot: palette.muted, reset: palette.reset)
                + paint(body, slot: palette.mark, reset: palette.reset)
        ]
    }
    let fallback = String(repeating: " ", count: commandLabel.count)
    let chunks = wrapLine(connector + body, width: max(16, width - fallback.count))
    return chunks.map { chunk in
        fallback + paint(chunk, slot: palette.mark, reset: palette.reset)
    }
}

private func paintedCommand(
    _ display: String,
    start: Int?,
    end: Int?,
    palette: Palette
) -> String {
    guard palette.colorsEnabled, let start, let end, start < display.count else {
        return display
    }
    let lower = display.index(display.startIndex, offsetBy: start)
    let upperOffset = min(end, display.count)
    let upper = display.index(display.startIndex, offsetBy: upperOffset)
    let before = String(display[..<lower])
    let matched = String(display[lower..<upper])
    let after = String(display[upper...])
    return before + paint(matched, slot: palette.deny, reset: palette.reset) + after
}

private func windowCommand(
    _ command: String,
    start: Int?,
    end: Int?,
    width: Int
) -> (display: String, start: Int?, end: Int?) {
    if command.count <= width {
        return clampedSpan(command, start: start, end: end)
    }
    let ellipsis = "..."
    guard let start, let end, end > start else {
        return (String(command.prefix(max(1, width - ellipsis.count))) + ellipsis, nil, nil)
    }

    let context = min(8, start)
    var origin = max(0, start - context)
    var lead = origin > 0
    var trail = true
    var inner = max(1, width - (lead ? ellipsis.count : 0) - ellipsis.count)
    var limit = min(command.count, origin + inner)
    if limit >= command.count {
        trail = false
        inner = max(1, width - (lead ? ellipsis.count : 0))
        origin = max(0, command.count - inner)
        lead = origin > 0
        if lead {
            inner = max(1, width - ellipsis.count)
            origin = max(0, command.count - inner)
        }
        limit = command.count
    }
    if start < origin {
        origin = start
        lead = origin > 0
        inner = max(1, width - (lead ? ellipsis.count : 0) - (trail ? ellipsis.count : 0))
        limit = min(command.count, origin + inner)
        trail = limit < command.count
    }

    let sliceStart = command.index(command.startIndex, offsetBy: origin)
    let sliceEnd = command.index(command.startIndex, offsetBy: limit)
    var display = String(command[sliceStart..<sliceEnd])
    var mappedStart = start - origin
    var mappedEnd = end - origin
    if lead {
        display = ellipsis + display
        mappedStart += ellipsis.count
        mappedEnd += ellipsis.count
    }
    if trail {
        display += ellipsis
    }
    return clampedSpan(display, start: mappedStart, end: mappedEnd)
}

private func clampedSpan(
    _ display: String,
    start: Int?,
    end: Int?
) -> (display: String, start: Int?, end: Int?) {
    guard let start, let end, end > start else {
        return (display, nil, nil)
    }
    let lo = max(0, start)
    if lo >= display.count {
        return (display, nil, nil)
    }
    let hi = min(max(lo + 1, end), display.count)
    return (display, lo, hi)
}

private func labeledField(
    _ label: String,
    _ value: String,
    valueSlot: String,
    palette: Palette,
    width: Int
) -> [String] {
    let prefix = "\(label): "
    let paintedPrefix = paint(prefix, slot: palette.muted, reset: palette.reset)
    let budget = max(16, width - prefix.count)
    let chunks = wrapLine(value, width: budget)
    guard let first = chunks.first else {
        return [paintedPrefix]
    }
    var lines = [paintedPrefix + paint(first, slot: valueSlot, reset: palette.reset)]
    for chunk in chunks.dropFirst() {
        lines.append(proseHang + paint(chunk, slot: valueSlot, reset: palette.reset))
    }
    return lines
}

private func labeledExplanation(_ body: [String], palette: Palette, width: Int) -> [String] {
    guard !body.isEmpty else {
        return [paint("Explanation:", slot: palette.muted, reset: palette.reset)]
    }
    var lines: [String] = []
    let prefix = "Explanation: "
    let paintedPrefix = paint(prefix, slot: palette.muted, reset: palette.reset)
    let firstBudget = max(16, width - prefix.count)
    if body[0].isEmpty {
        lines.append(paint("Explanation:", slot: palette.muted, reset: palette.reset))
    } else {
        let wrapped = wrapLine(body[0], width: firstBudget)
        if let head = wrapped.first {
            lines.append(paintedPrefix + head)
            for extra in wrapped.dropFirst() {
                lines.append(proseHang + extra)
            }
        }
    }
    for line in body.dropFirst() {
        if line.isEmpty {
            if lines.last != "" {
                lines.append("")
            }
            continue
        }
        if isSectionHeading(line) {
            if lines.last != "" {
                lines.append("")
            }
            lines.append("")
            lines.append(proseHang + paint(line, slot: palette.silver, reset: palette.reset))
            continue
        }
        if line.hasPrefix("• ") {
            let budget = max(16, width - bulletHang.count)
            for chunk in wrapLine(line, width: budget) {
                lines.append(bulletHang + chunk)
            }
            continue
        }
        if let preview = paintedPreview(line, palette: palette, width: width) {
            if lines.last != "" {
                lines.append("")
            }
            lines.append("")
            lines += preview
            continue
        }
        let budget = max(16, width - proseHang.count)
        for chunk in wrapLine(line, width: budget) {
            lines.append(proseHang + chunk)
        }
    }
    return lines
}

private func isSectionHeading(_ line: String) -> Bool {
    line.hasSuffix(":") && !line.hasPrefix("•")
}

private func paintedPreview(_ line: String, palette: Palette, width: Int) -> [String]? {
    guard line.hasPrefix("Preview ") else { return nil }
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let title = String(line[...colon])
    let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    let paintedTitle = paint(title, slot: palette.silver, reset: palette.reset)
    if rest.isEmpty {
        return [proseHang + paintedTitle]
    }
    let prefix = proseHang + title + " "
    let budget = max(16, width - prefix.count)
    let chunks = wrapLine(rest, width: budget)
    guard let first = chunks.first else {
        return [proseHang + paintedTitle]
    }
    var lines = [proseHang + paintedTitle + " " + first]
    for chunk in chunks.dropFirst() {
        lines.append(proseHang + chunk)
    }
    return lines
}

private func resultLine(_ model: TestViewModel, palette: Palette) -> String {
    let slot: String
    switch model.resultTone {
    case .allow:
        slot = palette.allow
    case .deny:
        slot = palette.deny
    case .incomplete:
        slot = palette.muted
    }
    return paint("Result: ", slot: palette.muted, reset: palette.reset)
        + paint(model.resultWord, slot: slot, reset: palette.reset)
}

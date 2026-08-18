import RVTheme

enum OutlineEmphasis: Equatable, Sendable {
    case plain
    case fact
    case muted
    case deny
    case allow
    case heading
    case mark
    case trace
}

enum OutlineItem: Equatable, Sendable {
    case leaf(label: String, value: String, emphasis: OutlineEmphasis)
    case regex(label: String, pattern: String)
    case text(String, emphasis: OutlineEmphasis)
    case group(label: String, emphasis: OutlineEmphasis, children: [OutlineItem])
    case spacer
}

func renderTree(
    root: String,
    emphasis: OutlineEmphasis,
    children: [OutlineItem],
    palette: Palette,
    labelWidth: Int = 12
) -> [String] {
    let head = paint(root, slot: slot(for: emphasis, palette: palette), reset: palette.reset)
    return [head] + renderOutline(children, palette: palette, labelWidth: labelWidth)
}

func renderOutline(_ items: [OutlineItem], palette: Palette, labelWidth: Int = 12) -> [String] {
    var lines: [String] = []
    walkOutline(items, ancestorsLast: [], palette: palette, labelWidth: labelWidth, into: &lines)
    return lines
}

private func walkOutline(
    _ items: [OutlineItem],
    ancestorsLast: [Bool],
    palette: Palette,
    labelWidth: Int,
    into lines: inout [String]
) {
    for (index, item) in items.enumerated() {
        let last = index == items.count - 1
        let prefix = outlinePrefix(ancestorsLast: ancestorsLast, last: last)
        let hang = outlineHang(ancestorsLast: ancestorsLast, last: last)
        switch item {
        case .leaf(let label, let value, let emphasis):
            let labelCol = padRight(label, to: labelWidth)
            let head = prefix + labelCol + " "
            let valueHang = hang + String(repeating: " ", count: labelCol.count + 1)
            lines += paintedWrap(
                prefix: head,
                hang: valueHang,
                body: value,
                slot: slot(for: emphasis, palette: palette),
                palette: palette,
                prefixSlot: palette.muted,
                prefixPaintCount: prefix.count + labelCol.count
            )
        case .regex(let label, let pattern):
            let labelCol = padRight(label, to: labelWidth)
            let head = prefix + labelCol + " "
            let valueHang = hang + String(repeating: " ", count: labelCol.count + 1)
            lines += paintedRegexWrap(
                prefix: head,
                hang: valueHang,
                pattern: pattern,
                palette: palette,
                prefixPaintCount: prefix.count + labelCol.count
            )
        case .text(let value, let emphasis):
            lines += paintedWrap(
                prefix: prefix,
                hang: hang,
                body: value,
                slot: slot(for: emphasis, palette: palette),
                palette: palette
            )
        case .group(let label, let emphasis, let children):
            lines += paintedWrap(
                prefix: prefix,
                hang: hang,
                body: label,
                slot: slot(for: emphasis, palette: palette),
                palette: palette
            )
            walkOutline(
                children,
                ancestorsLast: ancestorsLast + [last],
                palette: palette,
                labelWidth: labelWidth,
                into: &lines
            )
        case .spacer:
            lines.append(paint(hang, slot: palette.muted, reset: palette.reset))
        }
    }
}

private func outlinePrefix(ancestorsLast: [Bool], last: Bool) -> String {
    var prefix = ""
    for ancestorLast in ancestorsLast {
        prefix += ancestorLast ? "    " : "│   "
    }
    prefix += last ? "└── " : "├── "
    return prefix
}

private func outlineHang(ancestorsLast: [Bool], last: Bool) -> String {
    var prefix = ""
    for ancestorLast in ancestorsLast {
        prefix += ancestorLast ? "    " : "│   "
    }
    prefix += last ? "    " : "│   "
    return prefix
}

private func paintedRegexWrap(
    prefix: String,
    hang: String,
    pattern: String,
    palette: Palette,
    prefixPaintCount: Int
) -> [String] {
    let budget = max(16, 80 - prefix.count)
    let chunks = paintedRegexLines(pattern, width: budget, palette: palette)
    return chunks.enumerated().map { index, chunk in
        let lead = index == 0 ? prefix : hang
        let paintedLead: String
        if index == 0, lead.count >= prefixPaintCount {
            let end = lead.index(lead.startIndex, offsetBy: prefixPaintCount)
            paintedLead = paint(String(lead[..<end]), slot: palette.muted, reset: palette.reset)
                + String(lead[end...])
        } else {
            paintedLead = paint(lead, slot: palette.muted, reset: palette.reset)
        }
        return paintedLead + chunk
    }
}

private func paintedWrap(
    prefix: String,
    hang: String,
    body: String,
    slot: String,
    palette: Palette,
    prefixSlot: String? = nil,
    prefixPaintCount: Int? = nil
) -> [String] {
    let budget = max(16, 80 - prefix.count)
    let chrome = prefixSlot ?? palette.muted
    return wrapLine(body, width: budget).enumerated().map { index, chunk in
        let lead = index == 0 ? prefix : hang
        let paintedLead: String
        if index == 0, let count = prefixPaintCount, lead.count >= count {
            let end = lead.index(lead.startIndex, offsetBy: count)
            paintedLead = paint(String(lead[..<end]), slot: chrome, reset: palette.reset)
                + String(lead[end...])
        } else {
            paintedLead = paint(lead, slot: chrome, reset: palette.reset)
        }
        return paintedLead + paint(chunk, slot: slot, reset: palette.reset)
    }
}

private func slot(for emphasis: OutlineEmphasis, palette: Palette) -> String {
    switch emphasis {
    case .plain:
        return ""
    case .fact:
        return palette.fact
    case .muted:
        return palette.muted
    case .deny:
        return palette.deny
    case .allow:
        return palette.allow
    case .heading:
        return palette.heading
    case .mark:
        return palette.mark
    case .trace:
        return palette.trace
    }
}

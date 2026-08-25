import RVPresentation
import RVTheme

public struct PacksRenderer: FrameRenderer {
    public init() {}

    // Legacy flat (kept for PacksListFormatTests:2).
    public func render(_ model: PacksViewModel, palette: Palette) -> [String] {
        let width = model.rows.map(\.id.rawValue.count).max() ?? 0
        return model.rows.flatMap { row in
            let id = padRight(row.id.rawValue, to: width)
            let flag = row.enabled ? "on" : "off"
            let painted = paint(flag, slot: row.enabled ? palette.allow : palette.muted, reset: palette.reset)
            return wrapLine("\(id)  \(painted)")
        }
    }

    // Replica of upstream packs plain fallback + rich tree (src/output/tree.rs:1007):
    // Tree with Rounded guides (├──, ╰──, │), ●/○, verbose patterns, legend.
    public func renderGrouped(
        _ model: PacksGroupedViewModel,
        palette: Palette,
        verbose: Bool = false,
        expand: Bool = false,
        maxPatterns: Int = 10,
        collapsed: Bool = false
    ) -> [String] {
        if model.groups.isEmpty {
            return ["No packs match."]
        }
        // Collapsed path kept for legacy filtered --enabled; otherwise tree (default).
        if collapsed {
            var lines: [String] = []
            for group in model.groups {
                let enabled = group.packs.filter(\.enabled)
                let disabledCount = group.packs.count - enabled.count
                if enabled.isEmpty {
                    lines.append(paint("\(group.category): \(disabledCount) off", slot: palette.muted, reset: palette.reset))
                    continue
                }
                lines.append(paint("  \(group.category):", slot: palette.silver, reset: palette.reset))
                for row in enabled {
                    lines.append(packLine(row, palette: palette, verbose: verbose))
                    if verbose {
                        lines.append(contentsOf: patternLines(for: row, palette: palette, expand: expand, maxPatterns: maxPatterns))
                    }
                }
                if disabledCount > 0 {
                    lines.append(paint("    ○ \(disabledCount) off", slot: palette.muted, reset: palette.reset))
                }
            }
            return lines
        }

        // Tree replica — DCG rich `pack_list_tree` with Rounded guides.
        var categoryItems: [OutlineItem] = []
        for group in model.groups {
            var packItems: [OutlineItem] = []
            for pack in group.packs {
                let mark = pack.enabled ? "●" : "○"
                let emphasis: OutlineEmphasis = pack.enabled ? .allow : .muted
                let label: String
                if verbose {
                    let desc = singleLine(pack.description)
                    label = "\(mark) \(pack.id.rawValue) - \(desc) (\(pack.safePatternCount) safe, \(pack.destructivePatternCount) destructive)"
                } else {
                    label = "\(mark) \(pack.id.rawValue) - \(pack.name)"
                }
                if verbose && (!pack.safePatterns.isEmpty || !pack.destructivePatterns.isEmpty) {
                    var patternChildren: [OutlineItem] = []
                    let max = max(1, maxPatterns)
                    if !pack.safePatterns.isEmpty {
                        let total = pack.safePatterns.count
                        let title = (total > max && !expand) ? "Safe patterns (\(total) total)" : "Safe patterns"
                        let safeLines = pack.safePatterns.map { "\($0.name): \($0.pattern)" }
                        let truncated = truncatedForTree(safeLines, expand: expand, max: max)
                        let safeChildren = truncated.map { OutlineItem.text($0, emphasis: .plain) }
                        patternChildren.append(.group(label: title, emphasis: .muted, children: safeChildren))
                    }
                    if !pack.destructivePatterns.isEmpty {
                        let total = pack.destructivePatterns.count
                        let title = (total > max && !expand) ? "Destructive patterns (\(total) total)" : "Destructive patterns"
                        let destrLines = pack.destructivePatterns.map { "\($0.name) [\($0.severity.rawValue)]: \($0.pattern)" }
                        let truncated = truncatedForTree(destrLines, expand: expand, max: max)
                        let destrChildren = truncated.map { OutlineItem.text($0, emphasis: .plain) }
                        patternChildren.append(.group(label: title, emphasis: .muted, children: destrChildren))
                    }
                    packItems.append(.group(label: label, emphasis: emphasis, children: patternChildren))
                } else {
                    packItems.append(.text(label, emphasis: emphasis))
                }
            }
            categoryItems.append(.group(label: group.category, emphasis: .heading, children: packItems))
        }

        var lines = renderTree(root: "Available Packs", emphasis: .plain, children: categoryItems, palette: palette)
        lines.append("")
        lines.append(paint("Legend: ● = enabled, ○ = disabled", slot: palette.muted, reset: palette.reset))
        lines.append("")
        lines.append(paint("Enable packs in ~/.config/rv/config.toml", slot: palette.muted, reset: palette.reset))
        return lines
    }

    private func packLine(_ row: GroupedPackRow, palette: Palette, verbose: Bool) -> String {
        let mark = row.enabled ? "✓" : "○"
        let markSlot = row.enabled ? palette.allow : palette.muted
        let paintedMark = paint(mark, slot: markSlot, reset: palette.reset)
        let idPart = row.id.rawValue
        if verbose {
            let desc = singleLine(row.description)
            let counts = "(\(row.safePatternCount) safe, \(row.destructivePatternCount) destructive)"
            // Upstream: "    {} {} - {} ({} safe, {} destructive)"
            return "    \(paintedMark) \(idPart) - \(desc) \(counts)"
        } else {
            return "    \(paintedMark) \(idPart) - \(row.name)"
        }
    }

    private func patternLines(for row: GroupedPackRow, palette: Palette, expand: Bool, maxPatterns: Int) -> [String] {
        var out: [String] = []
        let max = max(1, maxPatterns)
        // Safe
        if !row.safePatterns.isEmpty {
            out.append(paint("      Safe patterns:", slot: palette.muted, reset: palette.reset))
            let safeStrings = row.safePatterns.map { "\($0.name): \($0.pattern)" }
            out.append(contentsOf: truncatedPatternLines(safeStrings, expand: expand, max: max))
        }
        // Destructive
        if !row.destructivePatterns.isEmpty {
            out.append(paint("      Destructive patterns:", slot: palette.muted, reset: palette.reset))
            let destrStrings = row.destructivePatterns.map {
                let sev = $0.severity.rawValue
                return "\($0.name) [\(sev)]: \($0.pattern)"
            }
            out.append(contentsOf: truncatedPatternLines(destrStrings, expand: expand, max: max))
        }
        return out
    }

    private func truncatedPatternLines(_ lines: [String], expand: Bool, max: Int) -> [String] {
        if lines.isEmpty { return [] }
        if expand || lines.count <= max {
            return lines.map { "        - \($0)" }
        }
        let head = (max + 1) / 2
        let tail = max - head
        let hidden = lines.count - head - tail
        var out: [String] = []
        for l in lines.prefix(head) {
            out.append("        - \(l)")
        }
        out.append("        - ... \(hidden) more patterns (--expand to show all)")
        if tail > 0 {
            for l in lines.suffix(tail) {
                out.append("        - \(l)")
            }
        }
        return out
    }

    private func truncatedForTree(_ lines: [String], expand: Bool, max: Int) -> [String] {
        if lines.isEmpty { return [] }
        if expand || lines.count <= max {
            return lines
        }
        let head = (max + 1) / 2
        let tail = max - head
        let hidden = lines.count - head - tail
        var out: [String] = []
        out.append(contentsOf: lines.prefix(head))
        out.append("... \(hidden) more patterns (--expand to show all)")
        out.append(contentsOf: lines.suffix(tail))
        return out
    }

    private func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

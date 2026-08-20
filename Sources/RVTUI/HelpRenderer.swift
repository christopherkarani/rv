import RVPresentation
import RVTheme

/// Vercel-quiet help: silver chrome + bold names. Green only on “start here” names.
public struct HelpRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: HelpViewModel, palette: Palette) -> [String] {
        var lines: [String] = []
        if model.title.isEmpty == false || model.blurb.isEmpty == false {
            lines.append(brandLine(model, palette: palette))
        }

        for section in model.sections where section.rows.isEmpty == false {
            appendBlank(&lines)
            lines.append(paint(section.heading, slot: palette.silver, reset: palette.reset))
            let nameWidth = section.rows.map(\.name.count).max() ?? 0
            let nameInk = section.accentNames ? palette.allow : palette.fact
            for row in section.rows {
                lines.append(contentsOf: renderRow(
                    row,
                    nameWidth: nameWidth,
                    nameInk: nameInk,
                    palette: palette
                ))
            }
        }

        if model.examples.isEmpty == false {
            appendBlank(&lines)
            lines.append(paint("Examples", slot: palette.silver, reset: palette.reset))
            for example in model.examples {
                let prefix = paint("  → ", slot: palette.silver, reset: palette.reset)
                lines.append(prefix + example)
            }
        }

        if model.next.isEmpty == false {
            appendBlank(&lines)
            lines.append(paint(model.nextHeading, slot: palette.silver, reset: palette.reset))
            let nameWidth = model.next.map(\.command.count).max() ?? 0
            for item in model.next {
                let name = padRight(item.command, to: nameWidth)
                let paintedName = paint(name, slot: palette.fact, reset: palette.reset)
                let desc = paint(item.description, slot: palette.silver, reset: palette.reset)
                lines.append("  \(paintedName)  \(desc)")
            }
        }

        return lines
    }

    private func appendBlank(_ lines: inout [String]) {
        if lines.isEmpty == false {
            lines.append("")
        }
    }

    private func brandLine(_ model: HelpViewModel, palette: Palette) -> String {
        let title = paint(model.title, slot: palette.fact, reset: palette.reset)
        if model.blurb.isEmpty {
            return title
        }
        let blurb = paint(model.blurb, slot: palette.silver, reset: palette.reset)
        return "\(title)  \(blurb)"
    }

    private func renderRow(
        _ row: HelpRow,
        nameWidth: Int,
        nameInk: String,
        palette: Palette
    ) -> [String] {
        if row.description.isEmpty {
            return ["  \(row.name)"]
        }
        let name = padRight(row.name, to: nameWidth)
        let paintedName = paint(name, slot: nameInk, reset: palette.reset)
        let desc = paint(row.description, slot: palette.silver, reset: palette.reset)
        return ["  \(paintedName)  \(desc)"]
    }
}

import RVPresentation
import RVTheme

/// Paints ceremony frames. Slot marks and progress use `Palette`; labels stay unpainted.
public struct SetupRenderer: Sendable {
    public static let progressWidth = 24
    /// Leading gutter so the show sits off the terminal edge.
    public static let leadingPad = "  "

    public init() {}

    public func render(_ model: SetupCeremonyFrame, palette: Palette) -> [String] {
        var lines: [String] = [""]
        if let title = model.title, title.isEmpty == false {
            lines.append(title)
        }
        if let progress = model.progress {
            lines.append(progressBar(progress, palette: palette))
        }
        if let status = model.statusLine, status.isEmpty == false {
            let tick = status.hasPrefix("✓")
                ? paint("✓", slot: palette.allow.isEmpty ? palette.heading : palette.allow, reset: palette.reset)
                  + String(status.dropFirst())
                : status
            lines.append(tick)
        }
        if model.activity != nil || model.spinnerIndex != nil {
            lines.append(activityLine(model, palette: palette))
        }
        if model.slots.isEmpty == false {
            if lines.last != "" {
                lines.append("")
            }
            for slot in model.slots {
                lines.append(row(slot, palette: palette))
            }
        }
        if model.closerLines.isEmpty == false {
            lines.append("")
            lines.append(contentsOf: model.closerLines)
        }
        return lines.map { $0.isEmpty ? $0 : Self.leadingPad + $0 }
    }

    /// Legacy static three-slot show (tests / fallback).
    public func render(_ model: SetupViewModel, palette: Palette) -> [String] {
        render(
            SetupCeremonyFrame(
                activity: model.activity,
                slots: model.slots,
                closerLines: [model.closer.title, model.closer.next]
            ),
            palette: palette
        )
    }

    private func activityLine(_ model: SetupCeremonyFrame, palette: Palette) -> String {
        let spin: String
        if let index = model.spinnerIndex {
            let frames = setupCeremonySpinnerFrames
            let glyph = frames[index % frames.count]
            spin = paint(glyph, slot: palette.heading, reset: palette.reset) + " "
        } else {
            spin = ""
        }
        return spin + (model.activity ?? "")
    }

    private func progressBar(_ progress: Double, palette: Palette) -> String {
        let clamped = min(1, max(0, progress))
        let filled = Int((clamped * Double(Self.progressWidth)).rounded(.down))
        let empty = Self.progressWidth - filled
        // Horizontal rules read thinner than full block █ / ░.
        let fill = String(repeating: "━", count: filled)
        let track = String(repeating: "─", count: empty)
        let paintedFill = paint(fill, slot: palette.heading, reset: palette.reset)
        let paintedTrack = paint(track, slot: palette.muted, reset: palette.reset)
        return paintedFill + paintedTrack
    }

    private func row(_ slot: SetupSlotView, palette: Palette) -> String {
        let filled = slot.kind == .wired
        let mark = filled ? "•" : "◦"
        let ink = filled ? palette.heading : palette.muted
        let painted = paint(mark, slot: ink, reset: palette.reset)
        var line = "\(painted)  \(slot.host.displayName)"
        if let clause = slot.clause, clause.isEmpty == false {
            line += "  \(clause)"
        }
        return line
    }
}

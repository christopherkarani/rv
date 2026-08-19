import RVPresentation
import RVTUI
import RVTheme

enum SetupAppearance: Equatable, Sendable {
    case robot
    case pretty(Palette)

    /// CI is one line, no circles. T2 `OutputMode` still maps CI+TTY browse to pretty.
    static func resolved(mode: OutputMode, ci: Bool, palette: Palette) -> SetupAppearance {
        if ci { return .robot }
        switch mode {
        case .robot:
            return .robot
        case .pretty, .browse:
            return .pretty(palette)
        }
    }
}

struct SetupReport: Equatable, Sendable {
    var grok: SetupSlotKind
    var pi: SetupSlotKind
    var openCode: SetupSlotKind
    var wrote: Set<SetupHostKind>

    var isHostless: Bool { detected.isEmpty }

    var hasWiredSlot: Bool {
        grok == .wired || pi == .wired || openCode == .wired
    }

    var occupied: [SetupHostKind] {
        SetupHostKind.allCases.filter { kind(for: $0) == .occupied }
    }

    var detected: [SetupHostKind] {
        SetupHostKind.allCases.filter { kind(for: $0) != .pending }
    }

    var isQuiet: Bool {
        detected.isEmpty == false && wrote.isEmpty && occupied.isEmpty
    }

    func kind(for host: SetupHostKind) -> SetupSlotKind {
        switch host {
        case .grok: grok
        case .pi: pi
        case .openCode: openCode
        }
    }
}

enum SetupFormat {
    static func stdout(report: SetupReport, appearance: SetupAppearance) -> String {
        switch appearance {
        case .robot:
            return robot(report)
        case .pretty(let palette):
            switch setupViewModel(
                grok: report.grok,
                pi: report.pi,
                openCode: report.openCode,
                wrote: report.wrote
            ) {
            case .quiet:
                return ""
            case .painted(let model):
                return PrettyWriter.join(SetupRenderer().render(model, palette: palette))
            }
        }
    }

    private static func robot(_ report: SetupReport) -> String {
        if report.isQuiet { return "" }
        if report.isHostless {
            return SetupRun.hostlessLine + "\n"
        }
        let skips = report.occupied.map(\.occupiedLine)
        if skips.isEmpty == false {
            return skips.joined(separator: "\n") + "\n"
        }
        return SetupRun.robotCompleteLine + "\n"
    }
}

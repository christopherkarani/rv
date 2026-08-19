import RVPresentation
import RVTUI
import RVTheme

enum SetupAppearance: Equatable, Sendable {
    case robot
    case pretty(Palette)
}

struct SetupReport: Equatable, Sendable {
    var grok: SetupSlotKind
    var pi: SetupSlotKind
    var openCode: SetupSlotKind
    var wrote: Set<SetupHost>
    var occupied: Set<SetupHost>
    var detected: Set<SetupHost>

    var isHostless: Bool { detected.isEmpty }

    var isQuiet: Bool {
        detected.isEmpty == false && wrote.isEmpty && occupied.isEmpty
    }

    func kind(for host: SetupHost) -> SetupSlotKind {
        switch host {
        case .grok: grok
        case .pi: pi
        case .openCode: openCode
        }
    }
}

enum SetupFormat {
    static let completeTitle = "Setup complete"
    static let completeNext = "Next  rv test 'git reset --hard'"
    static let hostlessTitle = "No hosts yet"
    static let hostlessNext = "Next  rv setup"
    static let looking = "looking for hosts"
    static let grokReloadClause = "reload /hooks"
    static let occupiedClause = "skipped occupied"

    static func stdout(report: SetupReport, appearance: SetupAppearance) -> String {
        switch appearance {
        case .robot:
            return robot(report)
        case .pretty(let palette):
            let model = viewModel(report)
            if model.isQuiet { return "" }
            return PrettyWriter.join(SetupRenderer().render(model, palette: palette))
        }
    }

    static func viewModel(_ report: SetupReport) -> SetupViewModel {
        SetupViewModel(
            slots: SetupHost.allCases.map { host in
                let kind = report.kind(for: host)
                return SetupSlotView(host: host.kind, kind: kind, clause: clause(host: host, kind: kind))
            },
            activity: activity(report),
            closerTitle: report.isHostless ? hostlessTitle : completeTitle,
            closerNext: report.isHostless ? hostlessNext : completeNext,
            isQuiet: report.isQuiet
        )
    }

    private static func robot(_ report: SetupReport) -> String {
        if report.isQuiet { return "" }
        if report.isHostless {
            return SetupRun.hostlessLine + "\n"
        }
        let skips = SetupHost.allCases.compactMap { host -> String? in
            report.occupied.contains(host) ? host.occupiedLine : nil
        }
        if skips.isEmpty == false {
            return skips.joined(separator: "\n") + "\n"
        }
        return SetupRun.robotCompleteLine + "\n"
    }

    private static func activity(_ report: SetupReport) -> String {
        let wired = SetupHost.allCases.last { report.wrote.contains($0) }
        if let wired {
            return "wiring \(wired.kind.displayName)"
        }
        return looking
    }

    private static func clause(host: SetupHost, kind: SetupSlotKind) -> String? {
        switch kind {
        case .wired where host == .grok:
            return grokReloadClause
        case .occupied:
            return occupiedClause
        case .pending, .wired:
            return nil
        }
    }
}

extension SetupHost {
    var kind: SetupHostKind {
        switch self {
        case .grok: .grok
        case .pi: .pi
        case .openCode: .openCode
        }
    }
}

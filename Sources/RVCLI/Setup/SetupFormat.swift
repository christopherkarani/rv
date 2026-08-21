import RVPresentation
import RVTUI
import RVTheme

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

struct UninstallReport: Equatable, Sendable {
    var removedHosts: Set<SetupHostKind>
    var occupiedHosts: Set<SetupHostKind>
    var removedLaunchAgent: Bool
    var removedBinaries: Bool
    var removedConfigArtifacts: Bool

    var didRemoveAnything: Bool {
        removedHosts.isEmpty == false
            || removedLaunchAgent
            || removedBinaries
            || removedConfigArtifacts
    }
}

enum SetupFormat {
    static func stdout(
        report: SetupReport,
        appearance: CLIAppearance,
        ceremonyKind: SetupCeremonyKind = .setup,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        animate: Bool = false,
        write: ((String) -> Void)? = nil
    ) -> (text: String, emitted: Bool) {
        switch appearance {
        case .robot:
            return (robot(report), false)
        case .pretty(let palette):
            guard let frames = setupCeremonyFrames(
                grok: report.grok,
                pi: report.pi,
                openCode: report.openCode,
                wrote: report.wrote,
                kind: ceremonyKind
            ) else {
                return ("", false)
            }
            return playCeremony(
                frames: frames,
                palette: palette,
                clock: clock,
                animate: animate,
                write: write
            )
        }
    }

    static func uninstallStdout(
        report: UninstallReport,
        appearance: CLIAppearance,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        animate: Bool = false,
        write: ((String) -> Void)? = nil
    ) -> (text: String, emitted: Bool) {
        switch appearance {
        case .robot:
            return (uninstallRobot(report), false)
        case .pretty(let palette):
            let frames = uninstallCeremonyFrames(
                removed: report.removedHosts,
                occupied: report.occupiedHosts,
                didRemoveAnything: report.didRemoveAnything
            )
            return playCeremony(
                frames: frames,
                palette: palette,
                clock: clock,
                animate: animate,
                write: write
            )
        }
    }

    private static func playCeremony(
        frames: [SetupCeremonyFrame],
        palette: Palette,
        clock: any SetupCeremonyClock,
        animate: Bool,
        write: ((String) -> Void)?
    ) -> (text: String, emitted: Bool) {
        if animate, let write {
            _ = SetupCeremonyPlayer.play(
                frames: frames,
                palette: palette,
                clock: clock,
                animate: true,
                write: write
            )
            return ("", true)
        }
        let text = SetupCeremonyPlayer.play(
            frames: frames,
            palette: palette,
            clock: ZeroSetupCeremonyClock(),
            animate: false,
            write: { _ in }
        )
        return (text, false)
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

    private static func uninstallRobot(_ report: UninstallReport) -> String {
        if report.didRemoveAnything {
            return SetupRun.uninstallCompleteLine + "\n"
        }
        return SetupRun.uninstallAlreadyCleanLine + "\n"
    }
}

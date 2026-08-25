import RVDomain
import RVPresentation
import RVTUI
import RVTheme

struct SetupReport: Equatable, Sendable {
    var slots: SetupSlotSnapshot

    init(
        grok: SetupSlotKind,
        pi: SetupSlotKind,
        openCode: SetupSlotKind,
        wrote: Set<HookHost>
    ) {
        slots = SetupSlotSnapshot(grok: grok, pi: pi, openCode: openCode, wrote: wrote)
    }

    var grok: SetupSlotKind { slots.grok }
    var pi: SetupSlotKind { slots.pi }
    var openCode: SetupSlotKind { slots.openCode }
    var wrote: Set<HookHost> { slots.wrote }
}

struct UninstallReport: Equatable, Sendable {
    var removedHosts: Set<HookHost>
    var occupiedHosts: Set<HookHost>
    var removedLaunchAgent: Bool
    var removedBinaries: Bool
    var removedConfigArtifacts: Bool

    /// Terminal outcome; single owner of the removed-vs-clean decision.
    var closer: UninstallCloser {
        let removedAnything = removedHosts.isEmpty == false
            || removedLaunchAgent
            || removedBinaries
            || removedConfigArtifacts
        return removedAnything
            ? .removed(hosts: removedHosts, occupied: occupiedHosts)
            : .alreadyClean(occupied: occupiedHosts)
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
            guard let frames = setupCeremonyFrames(report.slots, kind: ceremonyKind) else {
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
            let frames = uninstallCeremonyFrames(report.closer)
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
        switch report.slots.closer {
        case .quiet:
            ""
        case .hostless:
            setupRobotHostlessLine + "\n"
        case .complete(let skipped):
            ([setupRobotCompleteLine] + skipped.map(\.robotSkipLine)).joined(separator: ", ") + "\n"
        case .skipped(let skipped):
            skipped.map(\.robotSkipLine).joined(separator: ", ") + "\n"
        }
    }

    private static func uninstallRobot(_ report: UninstallReport) -> String {
        switch report.closer {
        case .removed:
            uninstallRobotCompleteLine + "\n"
        case .alreadyClean:
            uninstallRobotAlreadyCleanLine + "\n"
        }
    }
}

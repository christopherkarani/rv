import Foundation
import RVDomain
import RVPresentation

enum HostAttachOutcome: Equatable, Sendable {
    case occupied
    case wired(wrote: Bool)
}

/// Applies an executable attach plan. Write policy lives on the plan steps;
/// this type folds them.
enum HostLifecycle {
    static func attach(
        _ plan: SetupWorkPlan,
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) -> SetupReport {
        var slots = SetupSlotSnapshot(
            grok: .skipped,
            pi: .skipped,
            openCode: .skipped,
            claude: .skipped,
            openClaw: .skipped,
            hermes: .skipped,
            codex: .skipped,
            cursor: .skipped,
            wrote: []
        )

        for step in plan.steps {
            switch step {
            case .createConfigDirectory:
                do {
                    try files.createDirectory(atPath: layout.configDirectory)
                } catch {
                    throw SetupError.configDirectoryCreateFailed
                }
            case .skipLaunchAgent:
                break
            case .writeLaunchAgent:
                switch env.supervisor {
                case .launchd:
                    try SetupRun.writeLaunchAgent(
                        env: env,
                        layout: layout,
                        files: files,
                        keepAlive: env.companionPresence.presence().keepAlive
                    )
                case .systemdUser:
                    try SetupRun.writeSystemdUserUnit(env: env, layout: layout, files: files)
                }
            case .skipUndetected:
                break
            case .skipOccupied(let host):
                slots.assign(.occupied, to: host)
            case .forceClearThenWrite(let write), .write(let write):
                switch try perform(write, env: env, layout: layout, files: files) {
                case .occupied:
                    slots.assign(.occupied, to: write.host)
                case .wired(let wrote):
                    if wrote {
                        slots.wrote.insert(write.host)
                    }
                    slots.assign(.wired, to: write.host)
                }
            }
        }

        let report = SetupReport(
            grok: slots.grok,
            pi: slots.pi,
            openCode: slots.openCode,
            claude: slots.claude,
            openClaw: slots.openClaw,
            hermes: slots.hermes,
            codex: slots.codex,
            cursor: slots.cursor,
            wrote: slots.wrote
        )
        env.installAnalytics.captureInstall(hosts: InstallAnalyticsHosts.from(report.slots))
        return report
    }

    static func perform(
        _ write: HostAttachWrite,
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) -> HostAttachOutcome {
        switch write.prelude {
        case .none:
            break
        case .backupAndClearOwnedPath:
            do {
                try files.backupAndClearOwnedPath(write.destination)
            } catch {
                throw SetupError.hostHookClearFailed(write.host)
            }
        case .occupiedIfDestinationSymlink:
            if files.isSymbolicLink(write.destination) {
                return .occupied
            }
        }

        let existing: Data?
        switch write.existing {
        case .use(let data):
            existing = data
        case .useOrReread(let data):
            existing = data ?? files.readData(write.destination)
        case .reread:
            existing = files.readData(write.destination)
        case .noneAfterClear:
            existing = nil
        }

        let wrote = try SetupRun.writeArtifacts(
            write,
            existingData: existing,
            env: env,
            layout: layout,
            files: files
        )
        return .wired(wrote: wrote)
    }
}

private extension SetupSlotSnapshot {
    mutating func assign(_ kind: SetupSlotKind, to host: HookHost) {
        switch host {
        case .grok: grok = kind
        case .pi: pi = kind
        case .opencode: openCode = kind
        case .claude: claude = kind
        case .openclaw: openClaw = kind
        case .hermes: hermes = kind
        case .codex: codex = kind
        case .cursor: cursor = kind
        }
    }
}

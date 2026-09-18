import Foundation
import RVDomain
import RVPresentation

enum HostAttachOutcome: Equatable, Sendable {
    case occupied
    case wired(wrote: Bool)
}

struct UninstallHostResult: Equatable, Sendable {
    var removedHosts: Set<HookHost>
    var occupiedHosts: Set<HookHost>
    var removedPaths: [String]
}

/// Applies an executable attach or detach plan. Artifact policy lives on the
/// table; this type folds it.
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

    static func detach(
        installations: HostAdapterInstallationSnapshot,
        env _: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) -> UninstallHostResult {
        var removedHosts: Set<HookHost> = []
        var occupiedHosts: Set<HookHost> = []
        var removedPaths: [String] = []
        var stripOpenCodeAsk = false
        var emptyDirectories: [String] = []

        for owned in layout.hostAdapters {
            let write = HostArtifacts.detach(host: owned.host, layout: layout)
            emptyDirectories.append(contentsOf: write.alwaysEmptyDirectories)
            switch installations.installation(for: owned.host).uninstallPlan {
            case .remove:
                let enacted = try enact(write.remove, files: files)
                removedPaths.append(contentsOf: enacted.removedPaths)
                emptyDirectories.append(contentsOf: enacted.emptyDirectories)
                stripOpenCodeAsk = stripOpenCodeAsk || enacted.stripOpenCodeAsk
                if write.removedOnlyWhenChanged == false || enacted.changed {
                    removedHosts.insert(owned.host)
                }
            case .leaveOccupied:
                let enacted = try enact(write.leaveOccupied, files: files)
                removedPaths.append(contentsOf: enacted.removedPaths)
                emptyDirectories.append(contentsOf: enacted.emptyDirectories)
                stripOpenCodeAsk = stripOpenCodeAsk || enacted.stripOpenCodeAsk
                if write.removedOnlyWhenChanged {
                    if enacted.changed {
                        removedHosts.insert(owned.host)
                    } else {
                        occupiedHosts.insert(owned.host)
                    }
                } else {
                    occupiedHosts.insert(owned.host)
                }
            case .skip:
                break
            }
        }

        for path in removedPaths {
            files.removeFile(atPath: path)
        }
        if stripOpenCodeAsk {
            try SetupRun.stripOpenCodeAskPlugin(layout: layout, files: files)
        }
        for directory in emptyDirectories {
            files.removeDirectoryIfEmpty(atPath: directory)
        }

        return UninstallHostResult(
            removedHosts: removedHosts,
            occupiedHosts: occupiedHosts,
            removedPaths: removedPaths
        )
    }

    private struct DetachEnactment {
        var removedPaths: [String] = []
        var emptyDirectories: [String] = []
        var stripOpenCodeAsk = false
        var changed = false
    }

    private static func enact(
        _ operations: [HostDetachOperation],
        files: FileOps
    ) throws(SetupError) -> DetachEnactment {
        var enacted = DetachEnactment()
        for operation in operations {
            switch operation {
            case .removeFile(let path):
                enacted.removedPaths.append(path)
            case .removeClaudeRVHooks(let path):
                if try SetupRun.removeClaudeRVHooks(at: path, files: files) {
                    enacted.changed = true
                }
            case .stripClaudeFingerprintLeavingOccupied(let path):
                if try SetupRun.stripClaudeFingerprintLeavingOccupied(at: path, files: files) {
                    enacted.changed = true
                }
            case .removeCodexRVHooks(let path):
                _ = try SetupRun.removeCodexRVHooks(at: path, files: files)
            case .removeCursorRVHooks(let path):
                _ = try SetupRun.removeCursorRVHooks(at: path, files: files)
            case .stripOpenCodeAskPlugin:
                enacted.stripOpenCodeAsk = true
            case .removeEmptyDirectory(let path):
                enacted.emptyDirectories.append(path)
            }
        }
        return enacted
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

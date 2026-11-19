import Foundation
import RVDomain
import RVPresentation
import RVService

enum HostAttachOutcome: Equatable, Sendable {
    case occupied
    /// `agentSkillNote` names a skill rv kept or could not write; the hook
    /// is wired either way.
    case wired(wrote: Bool, agentSkillNote: AgentSkillNote? = nil)
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
            antigravity: .skipped,
            muse: .skipped,
            wrote: []
        )
        var serviceSkippedMissingRvd: String?
        var serviceStartedDirectly = false
        var runtimeMissing: [String: [HookHost]] = [:]
        var agentSkillNotes: [AgentSkillNote] = []

        for step in plan.steps {
            switch step {
            case .createConfigDirectory:
                do {
                    try files.createDirectory(atPath: layout.configDirectory)
                } catch {
                    throw SetupError.configDirectoryCreateFailed
                }
            case .skipLaunchAgent:
                // Only a run that owns the real supervisor can prove rvd
                // answers; an isolated HOME keeps the warning instead.
                guard env.managesService else {
                    serviceSkippedMissingRvd = env.rvdPath
                    break
                }
                throw SetupError.serviceDown(
                    .rvdMissing(env.rvdPath), alreadyWired: plan.alreadyWired, observing: observing(env))
            case .writeLaunchAgent:
                do {
                    serviceStartedDirectly = try startService(env: env, layout: layout, files: files)
                } catch {
                    throw SetupError.serviceDown(error, alreadyWired: plan.alreadyWired, observing: observing(env))
                }
            case .skipUndetected, .skipOff:
                break
            case .skipRuntimeMissing(let host, let interpreter):
                runtimeMissing[interpreter, default: []].append(host)
            case .skipOccupied(let host):
                slots.assign(.occupied, to: host)
            case .forceClearThenWrite(let write), .write(let write):
                switch try perform(write, env: env, layout: layout, files: files) {
                case .occupied:
                    slots.assign(.occupied, to: write.host)
                case .wired(let wrote, let agentSkillNote):
                    if let agentSkillNote {
                        agentSkillNotes.append(agentSkillNote)
                    }
                    if wrote {
                        slots.wrote.insert(write.host)
                    }
                    slots.assign(.wired, to: write.host)
                }
            }
        }

        var report = SetupReport(
            grok: slots.grok,
            pi: slots.pi,
            openCode: slots.openCode,
            claude: slots.claude,
            openClaw: slots.openClaw,
            hermes: slots.hermes,
            codex: slots.codex,
            cursor: slots.cursor,
            antigravity: slots.antigravity,
            muse: slots.muse,
            wrote: slots.wrote
        )
        report.serviceSkippedMissingRvd = serviceSkippedMissingRvd
        report.serviceStartedDirectly = serviceStartedDirectly
        report.unwiredForMissingInterpreter = runtimeMissing
        report.agentSkillNotes = agentSkillNotes
        env.installAnalytics.captureInstall(hosts: InstallAnalyticsHosts.from(report.slots))
        return report
    }

    private static func observing(_ env: SetupEnvironment) -> Bool {
        GuardConfig.read(home: env.home).machineMode == .observe
    }

    /// Installs and starts the service, then waits (bounded) for rvd to
    /// answer. Throws before any host is wired when it does not. True when
    /// rvd was started without a supervisor (Linux, no systemd user manager).
    private static func startService(
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) -> Bool {
        var direct = false
        switch env.supervisor {
        case .launchd:
            try SetupRun.writeLaunchAgent(
                env: env,
                layout: layout,
                files: files,
                keepAlive: env.companionPresence.presence().keepAlive
            )
            try SetupRun.writeCustodianLaunchAgent(env: env, layout: layout, files: files)
            try SetupRun.writeJudgeLaunchAgent(env: env, layout: layout, files: files)
        case .systemdUser:
            direct = try SetupRun.writeSystemdUserUnit(env: env, layout: layout, files: files) == .direct
        }
        guard env.managesService else { return direct }
        guard env.serviceAnswers() else {
            throw direct
                ? SetupError.directRvdNotAnswering(
                    rvdPath: env.rvdPath, logPath: RVDLogFile.path(home: env.home.rawValue))
                : SetupError.serviceNotAnswering(env.supervisor)
        }
        return direct
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
        guard let skill = write.agentSkill else { return .wired(wrote: wrote) }
        // After the hook: the skill only describes a gate that is in place.
        // Nothing here throws: a skill problem must not stop later hosts
        // from being wired.
        switch AgentSkill.install(at: skill, files: files) {
        case .wrote:
            return .wired(wrote: true)
        case .unchanged:
            return .wired(wrote: wrote)
        case .keptForeign:
            return .wired(wrote: wrote, agentSkillNote: .kept(path: skill))
        case .writeFailed(let reason):
            return .wired(wrote: wrote, agentSkillNote: .writeFailed(path: skill, reason: reason))
        }
    }

    /// Removes rv-owned hook artifacts. `only` scopes it to some hosts
    /// (`rv host mode <host> off`); nil is every host (`rv uninstall`).
    static func detach(
        installations: HostAdapterInstallationSnapshot,
        env _: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps,
        only: Set<HookHost>? = nil
    ) throws(SetupError) -> UninstallHostResult {
        var removedHosts: Set<HookHost> = []
        var occupiedHosts: Set<HookHost> = []
        var removedPaths: [String] = []
        var stripOpenCodeAsk = false
        var emptyDirectories: [String] = []

        for owned in layout.hostAdapters where only?.contains(owned.host) ?? true {
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
                // No hook left to remove, but a skill from an earlier
                // wiring may still be there.
                let enacted = try enact(write.remove.filter(\.isAgentSkillRemoval), files: files)
                removedPaths.append(contentsOf: enacted.removedPaths)
                emptyDirectories.append(contentsOf: enacted.emptyDirectories)
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
            case .removeAntigravityRVHooks(let path):
                if try SetupRun.removeAntigravityRVHooks(at: path, files: files) {
                    enacted.changed = true
                }
            case .stripAntigravityFingerprintLeavingOccupied(let path):
                if try SetupRun.stripAntigravityFingerprintLeavingOccupied(at: path, files: files) {
                    enacted.changed = true
                }
            case .removeCodexRVHooks(let path):
                _ = try SetupRun.removeCodexRVHooks(at: path, files: files)
            case .removeCursorRVHooks(let path):
                _ = try SetupRun.removeCursorRVHooks(at: path, files: files)
            case .removeMuseSettingsKey(let settingsPath, let hooksPath):
                _ = try SetupRun.removeMuseSettingsKey(
                    at: settingsPath,
                    hooksPath: hooksPath,
                    files: files
                )
            case .stripOpenCodeAskPlugin:
                enacted.stripOpenCodeAsk = true
            case .removeEmptyDirectory(let path):
                enacted.emptyDirectories.append(path)
            case .removeAgentSkill(let path):
                // Not `changed`: the skill never decides whether a host's
                // hook was removed or left occupied.
                if AgentSkill.isOwned(at: path, files: files) {
                    enacted.removedPaths.append(path)
                    enacted.emptyDirectories.append(contentsOf: AgentSkill.emptyDirectories(after: path))
                }
            }
        }
        return enacted
    }
}

private extension HostDetachOperation {
    var isAgentSkillRemoval: Bool {
        if case .removeAgentSkill = self { return true }
        return false
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
        case .antigravity: antigravity = kind
        case .muse: muse = kind
        }
    }
}

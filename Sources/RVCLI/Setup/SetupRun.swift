#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVAnalytics
import RVDomain
import RVHistory
import RVHooks
import RVPolicy
import RVPresentation

enum SetupRun {
    static let launchAgentLabel = "dev.rv.evaluate"

    static func setup(
        _ env: SetupEnvironment,
        appearance: CLIAppearance = .robot,
        ceremonyKind: SetupCeremonyKind = .setup,
        force: Bool = false,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        animate: Bool = false,
        write: ((String) -> Void)? = nil
    ) -> SetupOutcome {
        do {
            let report = try perform(env, force: force)
            let formatted = SetupFormat.stdout(
                report: report,
                appearance: appearance,
                ceremonyKind: ceremonyKind,
                clock: clock,
                animate: animate,
                write: write
            )
            return SetupOutcome(
                stdout: formatted.text,
                exitCode: 0,
                emitted: formatted.emitted
            )
        } catch {
            return failureOutcome(error, command: .setup)
        }
    }

    private static func failureOutcome(
        _ error: SetupError,
        command: SetupFailureCommand
    ) -> SetupOutcome {
        let output = setupFailureOutput(error, command: command)
        return SetupOutcome(stdout: "", stderr: output.stderr, exitCode: output.exitCode)
    }

    private static func perform(_ env: SetupEnvironment, force: Bool) throws(SetupError) -> SetupReport {
        let files = FileOps(fileManager: env.fileManager)
        let layout = OwnedPaths(home: env.home)
        let installations = try inspectInstallations(layout: layout, env: env)
        let plan = SetupWorkPlanBuilder.make(
            installations: installations,
            layout: layout,
            force: force,
            rvdIsExecutable: env.fileManager.isExecutableFile(atPath: env.rvdPath)
        )
        return try interpret(plan, env: env, layout: layout, files: files)
    }

    private static func interpret(
        _ plan: SetupWorkPlan,
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) -> SetupReport {
        var slots = SetupSlotSnapshot(
            grok: .pending,
            pi: .pending,
            openCode: .pending,
            claude: .pending,
            openClaw: .pending,
            hermes: .pending,
            codex: .pending,
            cursor: .pending,
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
                    try writeLaunchAgent(
                        env: env,
                        layout: layout,
                        files: files,
                        keepAlive: env.companionPresence.presence().keepAlive
                    )
                case .systemdUser:
                    try writeSystemdUserUnit(env: env, layout: layout, files: files)
                }
            case .skipUndetected(_):
                break
            case .skipOccupied(let host):
                slots.assign(.occupied, to: host)
            case .forceClearThenWrite(let host):
                if host == .claude {
                    let dest = layout.hostAdapter(for: host).destination
                    if files.isSymbolicLink(dest) {
                        slots.assign(.occupied, to: host)
                    } else {
                        let existingData = files.readData(dest)
                        if try writeClaudeSettings(
                            path: dest,
                            rvPath: env.rvPath,
                            existingData: existingData,
                            force: true,
                            files: files
                        ) {
                            slots.wrote.insert(host)
                        }
                        slots.assign(.wired, to: host)
                    }
                } else {
                    do {
                        try files.backupAndClearOwnedPath(layout.hostAdapter(for: host).destination)
                    } catch {
                        throw SetupError.hostHookClearFailed(host)
                    }
                    if try writeHost(
                        host,
                        existingData: nil,
                        env: env,
                        layout: layout,
                        files: files
                    ) {
                        slots.wrote.insert(host)
                    }
                    slots.assign(.wired, to: host)
                }
            case .write(let host, let existingData):
                if host == .claude {
                    let data = existingData ?? files.readData(layout.hostAdapter(for: host).destination)
                    if try writeClaudeSettings(
                        path: layout.hostAdapter(for: host).destination,
                        rvPath: env.rvPath,
                        existingData: data,
                        force: false,
                        files: files
                    ) {
                        slots.wrote.insert(host)
                    }
                    slots.assign(.wired, to: host)
                } else if try writeHost(
                    host,
                    existingData: existingData,
                    env: env,
                    layout: layout,
                    files: files
                ) {
                    slots.wrote.insert(host)
                    slots.assign(.wired, to: host)
                } else {
                    slots.assign(.wired, to: host)
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

    static func inspectInstallations(
        layout: OwnedPaths,
        env: SetupEnvironment
    ) throws(SetupError) -> HostAdapterInstallationSnapshot {
        do {
            return try HostAdapterInstallation.inspect(
                paths: layout,
                pathEntries: env.pathEntries,
                fileManager: env.fileManager
            )
        } catch let error as HostAdapterResourceError {
            throw SetupError(adapterResourceFailure: error)
        } catch {
            throw SetupError.inspectionFailed
        }
    }

    static func uninstall(
        _ env: SetupEnvironment,
        appearance: CLIAppearance = .robot,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        animate: Bool = false,
        write: ((String) -> Void)? = nil
    ) -> SetupOutcome {
        do {
            let formatted = try uninstallPerform(
                env,
                appearance: appearance,
                clock: clock,
                animate: animate,
                write: write
            )
            return SetupOutcome(
                stdout: formatted.text,
                exitCode: 0,
                emitted: formatted.emitted
            )
        } catch {
            return failureOutcome(error, command: .uninstall)
        }
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

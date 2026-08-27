#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVAnalytics
import RVDomain
import RVHooks
import RVPolicy
import RVPresentation

struct SetupOutcome: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    /// Pretty ceremony already wrote to the live sink; caller must not reprint `stdout`.
    var emitted: Bool

    init(stdout: String, stderr: String = "", exitCode: Int32, emitted: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.emitted = emitted
    }

    static let ok = SetupOutcome(stdout: "", exitCode: 0)
}

extension HookHost {
    func adapterResource() throws -> HostAdapterResource {
        try HostAdapterResources.load(for: self)
    }
}

struct SetupEnvironment {
    var home: HomeDirectory
    var pathEntries: [String]
    var rvPath: String
    var rvdPath: String
    var fileManager: FileManager
    var launchctl: any LaunchctlApplying
    var systemctl: any SystemctlApplying
    var touchLaunchd: Bool
    var touchSystemd: Bool
    var supervisor: EvaluateSupervisor
    var installAnalytics: any InstallAnalyticsCapturing
    /// Injected so launchd domains are provable without the real uid.
    var uid: () -> uid_t = { getuid() }

    /// Curl install copies `rv` (C hook), `rv-cli`, and `rvd`.
    /// Adapters bake `$HOME/.local/bin/rv`, not `rv-cli`. Do not walk PATH.
    static func resolveRv(home: String) -> String {
        home + "/.local/bin/rv"
    }

    /// Prefer `rvd` next to the running `rv` / `rv-cli`, then `$HOME/.local/bin/rvd`.
    static func resolveRvd(
        nextTo rvExecutable: String?,
        home: String,
        fileManager: FileManager = .default
    ) -> String? {
        if let rvExecutable {
            let sibling = (rvExecutable as NSString).deletingLastPathComponent + "/rvd"
            if fileManager.isExecutableFile(atPath: sibling) {
                return sibling
            }
        }
        let local = home + "/.local/bin/rvd"
        if fileManager.isExecutableFile(atPath: local) {
            return local
        }
        return nil
    }
}

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
                    try writeLaunchAgent(env: env, layout: layout, files: files)
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

    private static func writeHost(
        _ host: HookHost,
        existingData: Data?,
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) -> Bool {
        let adapter: HostAdapterResource
        do {
            adapter = try HostAdapterResources.load(for: host)
        } catch {
            throw SetupError(adapterResourceFailure: error)
        }
        do {
            let destination = layout.hostAdapter(for: host).destination
            let wroteAdapter = try writeOwned(
                path: destination,
                contents: adapter.rendered(rvPath: env.rvPath),
                existingData: existingData,
                files: files
            )
            let wroteCompanions = try writeCompanions(
                host,
                directory: (destination as NSString).deletingLastPathComponent,
                layout: layout,
                files: files
            )
            return wroteAdapter || wroteCompanions
        } catch {
            throw SetupError.hostHookWriteFailed(host)
        }
    }

    private static func writeCompanions(
        _ host: HookHost,
        directory: String,
        layout: OwnedPaths,
        files: FileOps
    ) throws -> Bool {
        switch host {
        case .openclaw:
            let pluginJSON = try HostAdapterResources.loadPluginManifest(for: host)
            let packageJSON = try HostAdapterResources.loadPackageManifest(for: host)
            let pluginPath = directory + "/openclaw.plugin.json"
            let packagePath = directory + "/package.json"
            let wrotePlugin = try writeOwned(
                path: pluginPath,
                contents: pluginJSON,
                existingData: files.readData(pluginPath),
                files: files
            )
            let wrotePackage = try writeOwned(
                path: packagePath,
                contents: packageJSON,
                existingData: files.readData(packagePath),
                files: files
            )
            return wrotePlugin || wrotePackage
        case .hermes:
            let pluginYAML = try HostAdapterResources.loadPluginManifest(for: host)
            let pluginPath = directory + "/plugin.yaml"
            return try writeOwned(
                path: pluginPath,
                contents: pluginYAML,
                existingData: files.readData(pluginPath),
                files: files
            )
        case .opencode:
            let tui = try HostAdapterResources.loadOpenCodeTuiPlugin()
            let wroteTui = try writeOwned(
                path: directory + "/rv-guard-tui.js",
                contents: tui,
                existingData: files.readData(directory + "/rv-guard-tui.js"),
                files: files
            )
            let wroteAsk = try writeOpenCodeTuiAskPackage(layout: layout, files: files)
            return wroteTui || wroteAsk
        case .codex:
            return try writeCodexHooksJSON(
                adapterPath: directory + "/rv-guard.py",
                hooksPath: (directory as NSString).deletingLastPathComponent + "/hooks.json",
                files: files
            )
        case .cursor:
            return try writeCursorHooksJSON(
                adapterPath: directory + "/rv-guard.py",
                hooksPath: (directory as NSString).deletingLastPathComponent + "/hooks.json",
                files: files
            )
        case .grok, .pi, .claude:
            return false
        }
    }

    private static func writeOpenCodeTuiAskPackage(layout: OwnedPaths, files: FileOps) throws -> Bool {
        let packageJSONPath = layout.openCodeTuiAskPackage + "/package.json"
        let tuiPath = layout.openCodeTuiAskPackage + "/tui.js"
        let wrotePackage = try writeOwned(
            path: packageJSONPath,
            contents: OpenCodeTuiAskPackage.packageJSON,
            existingData: files.readData(packageJSONPath),
            files: files
        )
        let wroteTui = try writeOwned(
            path: tuiPath,
            contents: OpenCodeTuiAskPackage.tuiJS,
            existingData: files.readData(tuiPath),
            files: files
        )
        var wroteConfig = false
        do {
            let merged = try OpenCodeConfigMerge.merge(
                existingData: files.readData(layout.openCodeConfig),
                pluginPath: layout.openCodeTuiAskPackage
            )
            if merged.wrote {
                try files.writeData(merged.data, to: layout.openCodeConfig)
                wroteConfig = true
            }
        } catch OpenCodeConfigMergeError.invalidJSON {
            // Foreign / broken config stays; globbed server() plugin still loads.
        }
        return wrotePackage || wroteTui || wroteConfig
    }

    private static func stripOpenCodeAskPlugin(layout: OwnedPaths, files: FileOps) throws(SetupError) {
        guard let existing = files.readData(layout.openCodeConfig) else {
            return
        }
        let next: Data?
        do {
            next = try OpenCodeConfigMerge.strip(
                existingData: existing,
                pluginPath: layout.openCodeTuiAskPackage
            )
        } catch OpenCodeConfigMergeError.invalidJSON {
            return
        } catch {
            throw SetupError.hostHookWriteFailed(.opencode)
        }
        do {
            if let next {
                if next != existing {
                    try files.writeData(next, to: layout.openCodeConfig)
                }
            } else {
                files.removeFile(atPath: layout.openCodeConfig)
            }
        } catch {
            throw SetupError.hostHookWriteFailed(.opencode)
        }
    }

    private static func inspectInstallations(
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

    private static func uninstallPerform(
        _ env: SetupEnvironment,
        appearance: CLIAppearance,
        clock: any SetupCeremonyClock,
        animate: Bool,
        write: ((String) -> Void)?
    ) throws(SetupError) -> (text: String, emitted: Bool) {
        let files = FileOps(fileManager: env.fileManager)
        let layout = OwnedPaths(home: env.home)
        let installations = try inspectInstallations(layout: layout, env: env)

        var removedHosts: Set<HookHost> = []
        var occupiedHosts: Set<HookHost> = []
        var removedPaths: [String] = []
        var stripOpenCodeAsk = false

        for owned in layout.hostAdapters {
            switch installations.installation(for: owned.host).uninstallPlan {
            case .remove:
                if owned.host == .claude {
                    if try removeClaudeRVHooks(at: owned.destination, files: files) {
                        removedHosts.insert(owned.host)
                    }
                } else {
                    removedPaths.append(owned.destination)
                    if owned.host == .openclaw {
                        let directory = (owned.destination as NSString).deletingLastPathComponent
                        removedPaths.append(directory + "/openclaw.plugin.json")
                        removedPaths.append(directory + "/package.json")
                    }
                    if owned.host == .hermes {
                        let directory = (owned.destination as NSString).deletingLastPathComponent
                        removedPaths.append(directory + "/plugin.yaml")
                    }
                    if owned.host == .codex {
                        _ = try removeCodexRVHooks(at: layout.codexHooksJSON, files: files)
                    }
                    if owned.host == .cursor {
                        _ = try removeCursorRVHooks(at: layout.cursorHooksJSON, files: files)
                    }
                    if owned.host == .opencode {
                        removedPaths.append(layout.openCodeTuiPlugin)
                        removedPaths.append(layout.openCodeTuiAskPackage + "/package.json")
                        removedPaths.append(layout.openCodeTuiAskPackage + "/tui.js")
                        stripOpenCodeAsk = true
                    }
                    removedHosts.insert(owned.host)
                }
            case .leaveOccupied:
                if owned.host == .claude {
                    if try stripClaudeFingerprintLeavingOccupied(at: owned.destination, files: files) {
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

        let servicePath = evaluateServicePath(layout: layout, supervisor: env.supervisor)
        let launchAgentExisted = files.fileExists(servicePath)
        let binariesExisted = files.fileExists(layout.localRv)
            || files.fileExists(layout.localRvCli)
            || files.fileExists(layout.localRvd)
        removedPaths.append(
            contentsOf: [servicePath, layout.localRv, layout.localRvCli, layout.localRvd]
        )

        let configDir = URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        let analytics = AnalyticsPaths(configDirectory: configDir)
        let configArtifacts =
            analytics.uninstallArtifacts + RVPolicyPaths.uninstallArtifacts(inConfigDir: configDir)
        let configExisted = configArtifacts.contains { files.fileExists($0.path) }
        for artifact in configArtifacts {
            removedPaths.append(artifact.path)
        }

        for path in removedPaths {
            files.removeFile(atPath: path)
        }
        if stripOpenCodeAsk {
            try stripOpenCodeAskPlugin(layout: layout, files: files)
            files.removeDirectoryIfEmpty(atPath: layout.openCodeTuiAskPackage)
        }
        files.removeDirectoryIfEmpty(
            atPath: (layout.openClawPlugin as NSString).deletingLastPathComponent
        )
        files.removeDirectoryIfEmpty(
            atPath: (layout.hermesPlugin as NSString).deletingLastPathComponent
        )
        files.removeDirectoryIfEmpty(
            atPath: (layout.codexHook as NSString).deletingLastPathComponent
        )
        files.removeDirectoryIfEmpty(
            atPath: (layout.cursorHook as NSString).deletingLastPathComponent
        )
        files.removeDirectoryIfEmpty(atPath: layout.configDirectory)

        if env.supervisor == .launchd, env.touchLaunchd {
            let uid = env.uid()
            try? env.launchctl.bootout(domain: LaunchdDomain.user(uid), label: launchAgentLabel)
            do {
                try env.launchctl.bootout(domain: LaunchdDomain.gui(uid), label: launchAgentLabel)
            } catch {
                throw SetupError.launchctlApplyFailed(.bootout)
            }
        }
        if env.supervisor == .systemdUser, env.touchSystemd {
            do {
                try env.systemctl.disableNow(unit: SystemdUserTemplate.unitName)
            } catch {
                throw SetupError.systemdApplyFailed(.disable)
            }
        }

        if removedPaths.contains(where: { files.fileExists($0) }) {
            throw SetupError.ownedPathStillExists
        }

        let report = UninstallReport(
            removedHosts: removedHosts,
            occupiedHosts: occupiedHosts,
            removedLaunchAgent: launchAgentExisted,
            removedBinaries: binariesExisted,
            removedConfigArtifacts: configExisted
        )
        return SetupFormat.uninstallStdout(
            report: report,
            appearance: appearance,
            clock: clock,
            animate: animate,
            write: write
        )
    }

    /// Merges the Codex PreToolUse registration for `adapterPath` into `hooks.json`.
    private static func writeCodexHooksJSON(
        adapterPath: String,
        hooksPath: String,
        files: FileOps
    ) throws(SetupError) -> Bool {
        if files.isSymbolicLink(hooksPath) {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        let merged: (data: Data, wrote: Bool)
        do {
            merged = try CodexHooksMerge.merge(
                existingData: files.readData(hooksPath),
                adapterPath: adapterPath
            )
        } catch {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        if merged.wrote == false {
            return false
        }
        do {
            try files.writeData(merged.data, to: hooksPath)
        } catch {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        return true
    }

    /// Merges the Cursor beforeShellExecution registration for `adapterPath` into `hooks.json`.
    private static func writeCursorHooksJSON(
        adapterPath: String,
        hooksPath: String,
        files: FileOps
    ) throws(SetupError) -> Bool {
        if files.isSymbolicLink(hooksPath) {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        let merged: (data: Data, wrote: Bool)
        do {
            merged = try CursorHooksMerge.merge(
                existingData: files.readData(hooksPath),
                adapterPath: adapterPath
            )
        } catch {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        if merged.wrote == false {
            return false
        }
        do {
            try files.writeData(merged.data, to: hooksPath)
        } catch {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        return true
    }

    /// Removes rv-fingerprinted Cursor handlers only. Returns whether anything changed.
    private static func removeCursorRVHooks(at path: String, files: FileOps) throws(SetupError) -> Bool {
        if files.isSymbolicLink(path) {
            return false
        }
        guard let data = files.readData(path) else { return false }
        let next: Data?
        do {
            next = try CursorHooksMerge.uninstall(existingData: data)
        } catch {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        guard let next else {
            files.removeFile(atPath: path)
            return true
        }
        if next == data {
            return false
        }
        do {
            try files.writeData(next, to: path)
        } catch {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        return true
    }

    /// Removes rv-fingerprinted Codex handlers only. Returns whether anything changed.
    private static func removeCodexRVHooks(at path: String, files: FileOps) throws(SetupError) -> Bool {
        if files.isSymbolicLink(path) {
            return false
        }
        guard let data = files.readData(path) else { return false }
        let next: Data?
        do {
            next = try CodexHooksMerge.uninstall(existingData: data)
        } catch {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        guard let next else {
            files.removeFile(atPath: path)
            return true
        }
        if next == data {
            return false
        }
        do {
            try files.writeData(next, to: path)
        } catch {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        return true
    }

    private static func writeLaunchAgent(
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) {
        let body = try LaunchAgentTemplate.rendered(rvdPath: env.rvdPath)
        do {
            try files.write(body, to: layout.launchAgent)
        } catch {
            throw SetupError.launchAgentWriteFailed
        }
        if env.touchLaunchd {
            try loadLaunchAgent(env: env, plist: URL(fileURLWithPath: layout.launchAgent))
        }
    }

    /// `launchctl bootstrap` if needed. Already-registered (exit 5) is success
    /// when `print` shows the job. Prefer `gui/`; fall back to `user/` when Aqua
    /// is missing so `curl | sh` from a Background session still completes.
    private static func loadLaunchAgent(env: SetupEnvironment, plist: URL) throws(SetupError) {
        let uid = env.uid()
        for domain in LaunchdDomain.bootoutOrder(uid: uid) {
            try? env.launchctl.bootout(domain: domain, label: launchAgentLabel)
        }
        for domain in LaunchdDomain.bootstrapOrder(uid: uid) {
            if acceptBootstrap(env.launchctl, domain: domain, plist: plist) {
                return
            }
        }
        throw SetupError.launchctlApplyFailed(.bootstrap)
    }

    private static func acceptBootstrap(
        _ launchctl: any LaunchctlApplying,
        domain: String,
        plist: URL
    ) -> Bool {
        do {
            try launchctl.bootstrap(domain: domain, plist: plist)
            return true
        } catch {
            return launchctl.isLoaded(domain: domain, label: launchAgentLabel)
        }
    }

    private static func writeSystemdUserUnit(
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) {
        let body = try SystemdUserTemplate.rendered(rvdPath: env.rvdPath)
        do {
            try files.write(body, to: layout.systemdUserUnit)
        } catch {
            throw SetupError.systemdUnitWriteFailed
        }
        if env.touchSystemd {
            do {
                try env.systemctl.enableNow(unit: SystemdUserTemplate.unitName)
            } catch {
                throw SetupError.systemdApplyFailed(.enable)
            }
        }
    }

    private static func evaluateServicePath(layout: OwnedPaths, supervisor: EvaluateSupervisor) -> String {
        switch supervisor {
        case .launchd:
            layout.launchAgent
        case .systemdUser:
            layout.systemdUserUnit
        }
    }

    /// Writes Claude settings merge when missing or different. Returns whether a write occurred.
    private static func writeClaudeSettings(
        path: String,
        rvPath: String,
        existingData: Data?,
        force: Bool,
        files: FileOps
    ) throws(SetupError) -> Bool {
        if files.isSymbolicLink(path) {
            return false
        }
        let merged: (data: Data, wrote: Bool)
        do {
            merged = try ClaudeSettingsMerge.merge(
                existingData: existingData,
                rvPath: rvPath,
                force: force
            )
        } catch {
            throw SetupError.hostHookWriteFailed(.claude)
        }
        if merged.wrote == false {
            return false
        }
        do {
            try files.writeData(merged.data, to: path)
        } catch {
            throw SetupError.hostHookWriteFailed(.claude)
        }
        return true
    }

    /// Removes rv-fingerprinted Claude handlers only. Returns whether anything changed.
    private static func removeClaudeRVHooks(at path: String, files: FileOps) throws(SetupError) -> Bool {
        try applyClaudeUninstall(at: path, files: files, unreadable: .fail)
    }

    /// Stale rv fingerprints are occupied for setup, but uninstall still strips them.
    private static func stripClaudeFingerprintLeavingOccupied(
        at path: String,
        files: FileOps
    ) throws(SetupError) -> Bool {
        try applyClaudeUninstall(at: path, files: files, unreadable: .leave)
    }

    private enum ClaudeUnreadableUninstall {
        case fail
        case leave
    }

    private static func applyClaudeUninstall(
        at path: String,
        files: FileOps,
        unreadable: ClaudeUnreadableUninstall
    ) throws(SetupError) -> Bool {
        if files.isSymbolicLink(path) {
            return false
        }
        guard let data = files.readData(path) else { return false }
        let next: Data?
        do {
            next = try ClaudeSettingsMerge.uninstall(existingData: data)
        } catch {
            switch unreadable {
            case .fail:
                throw SetupError.hostHookWriteFailed(.claude)
            case .leave:
                return false
            }
        }
        guard let next else {
            files.removeFile(atPath: path)
            return true
        }
        if next == data {
            return false
        }
        do {
            try files.writeData(next, to: path)
        } catch {
            throw SetupError.hostHookWriteFailed(.claude)
        }
        return true
    }

    /// Writes `contents` when missing or different. Returns whether a write occurred.
    private static func writeOwned(
        path: String,
        contents: String,
        existingData: Data?,
        files: FileOps
    ) throws -> Bool {
        let payload = Data(contents.utf8)
        if existingData == payload {
            return false
        }
        try files.write(contents, to: path)
        return true
    }
}

enum FileOpsError: Error, Equatable, Sendable {
    case symbolicLink
}

struct FileOps {
    var fileManager: FileManager

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func fileExists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func readData(_ path: String) -> Data? {
        fileManager.contents(atPath: path)
    }

    func write(_ contents: String, to path: String) throws {
        try createDirectory(atPath: (path as NSString).deletingLastPathComponent)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func writeData(_ data: Data, to path: String) throws {
        try createDirectory(atPath: (path as NSString).deletingLastPathComponent)
        if isSymbolicLink(path) {
            throw FileOpsError.symbolicLink
        }
        let mode = posixMode(at: path) ?? 0o600
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func isSymbolicLink(_ path: String) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func posixMode(at path: String) -> Int? {
        guard let raw = (try? fileManager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber else {
            return nil
        }
        return raw.intValue & 0o777
    }

    func createDirectory(atPath path: String) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func removeFile(atPath path: String) {
        guard fileManager.fileExists(atPath: path) else { return }
        try? fileManager.removeItem(atPath: path)
    }

    func removeDirectoryIfEmpty(atPath path: String) {
        guard isDirectory(path) else { return }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path), contents.isEmpty else {
            return
        }
        try? fileManager.removeItem(atPath: path)
    }

    /// Moves an occupied owned path aside (`path.bak`) so setup can rewrite it.
    /// Symlinks are removed without a backup (nothing useful to restore as bytes).
    func backupAndClearOwnedPath(_ path: String) throws {
        if isSymbolicLink(path) {
            try fileManager.removeItem(atPath: path)
            return
        }
        guard fileManager.fileExists(atPath: path) else { return }
        let backup = path + ".bak"
        if fileManager.fileExists(atPath: backup) {
            try fileManager.removeItem(atPath: backup)
        }
        try fileManager.moveItem(atPath: path, toPath: backup)
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

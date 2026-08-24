import Foundation
import RVAnalytics
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

extension SetupHostKind {
    func adapterResource() throws -> HostAdapterResource {
        try HostAdapterResources.load(for: hookHost)
    }

    private var hookHost: HookHost {
        switch self {
        case .grok: .grok
        case .pi: .pi
        case .openCode: .opencode
        }
    }

}

struct SetupEnvironment {
    var home: String
    var pathEntries: [String]
    var rvPath: String
    var rvdPath: String
    var fileManager: FileManager
    var launchctl: any LaunchctlApplying
    var touchLaunchd: Bool
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

    /// The flow door injects `capture` so install-analytics policy stays behind the door.
    static func setup(
        _ env: SetupEnvironment,
        appearance: CLIAppearance = .robot,
        ceremonyKind: SetupCeremonyKind = .setup,
        force: Bool = false,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        animate: Bool = false,
        write: ((String) -> Void)? = nil,
        capture: (SetupSlotSnapshot) -> Void = { _ in }
    ) -> SetupOutcome {
        do {
            let report = try perform(env, force: force)
            capture(report.slots)
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
        var kinds: [SetupHostKind: SetupSlotKind] = [
            .grok: .pending,
            .pi: .pending,
            .openCode: .pending,
        ]
        var wrote: Set<SetupHostKind> = []

        do {
            try files.createDirectory(atPath: layout.configDirectory)
        } catch {
            throw SetupError.configDirectoryCreateFailed
        }
        try writeLaunchAgent(env: env, layout: layout, files: files)

        for owned in layout.hostAdapters {
            let host = owned.host
            let existingData: Data?
            switch installations.installation(for: host).setupPlan(force: force) {
            case .skipUndetected:
                continue
            case .skipOccupied:
                kinds[host] = .occupied
                continue
            case .forceClearThenWrite:
                do {
                    try files.backupAndClearOwnedPath(owned.destination)
                } catch {
                    throw SetupError.hostHookClearFailed(host)
                }
                existingData = nil
            case .write(let data):
                existingData = data
            }
            let adapter: HostAdapterResource
            do {
                adapter = try HostAdapterResources.load(for: owned.hookHost)
            } catch {
                throw SetupError(adapterResourceFailure: error)
            }
            let wroteHook: Bool
            do {
                wroteHook = try writeOwned(
                    path: owned.destination,
                    contents: adapter.rendered(rvPath: env.rvPath),
                    existingData: existingData,
                    files: files
                )
            } catch {
                throw SetupError.hostHookWriteFailed(host)
            }
            if wroteHook {
                wrote.insert(host)
            }
            kinds[host] = .wired
        }

        let report = SetupReport(
            grok: kinds[.grok] ?? .pending,
            pi: kinds[.pi] ?? .pending,
            openCode: kinds[.openCode] ?? .pending,
            wrote: wrote
        )
        return report
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

        var removedHosts: Set<SetupHostKind> = []
        var occupiedHosts: Set<SetupHostKind> = []
        var removedPaths: [String] = []

        for owned in layout.hostAdapters {
            switch installations.installation(for: owned.host).uninstallPlan {
            case .remove:
                removedPaths.append(owned.destination)
                removedHosts.insert(owned.host)
            case .leaveOccupied:
                occupiedHosts.insert(owned.host)
            case .skip:
                break
            }
        }

        let launchAgentExisted = files.fileExists(layout.launchAgent)
        let binariesExisted = files.fileExists(layout.localRv)
            || files.fileExists(layout.localRvCli)
            || files.fileExists(layout.localRvd)
        removedPaths.append(
            contentsOf: [layout.launchAgent, layout.localRv, layout.localRvCli, layout.localRvd]
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
        files.removeDirectoryIfEmpty(atPath: layout.configDirectory)

        if env.touchLaunchd {
            do {
                try env.launchctl.bootout(domain: "gui/\(env.uid())", label: launchAgentLabel)
            } catch {
                throw SetupError.launchctlApplyFailed(.bootout)
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

    private static func writeLaunchAgent(
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) {
        guard env.fileManager.isExecutableFile(atPath: env.rvdPath) else {
            return
        }
        let body = try LaunchAgentTemplate.rendered(rvdPath: env.rvdPath)
        do {
            try files.write(body, to: layout.launchAgent)
        } catch {
            throw SetupError.launchAgentWriteFailed
        }
        if env.touchLaunchd {
            let url = URL(fileURLWithPath: layout.launchAgent)
            try? env.launchctl.bootout(domain: "gui/\(env.uid())", label: launchAgentLabel)
            do {
                try env.launchctl.bootstrap(domain: "gui/\(env.uid())", plist: url)
            } catch {
                throw SetupError.launchctlApplyFailed(.bootstrap)
            }
        }
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
        if (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil {
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

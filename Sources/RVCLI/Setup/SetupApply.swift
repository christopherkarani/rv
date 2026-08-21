import Foundation
import RVAnalytics
import RVHooks
import RVPolicy
import RVPresentation

enum SetupApplyError: Error, Equatable, Sendable {
    case inspectFailed
    case launchAgentUnloadFailed
    case leftoverOwnedPath

    var stderr: String {
        switch self {
        case .inspectFailed:
            "rv uninstall failed: unable to inspect Host adapters\n"
        case .launchAgentUnloadFailed:
            "rv uninstall failed: unable to unload LaunchAgent\n"
        case .leftoverOwnedPath:
            "rv uninstall failed: owned path still exists\n"
        }
    }
}

enum SetupApply {
    static func setup(_ env: SetupEnvironment, force: Bool) throws -> SetupReport {
        let files = FileOps(fileManager: env.fileManager)
        let layout = OwnedPaths(home: env.home)
        let installations = try HostAdapterInstallation.inspect(
            paths: layout,
            pathEntries: env.pathEntries,
            fileManager: env.fileManager
        )
        try files.createDirectory(atPath: layout.configDirectory)
        try writeLaunchAgent(env: env, layout: layout, files: files)

        let applied = try applyHosts(
            layout: layout,
            installations: installations,
            env: env,
            force: force,
            files: files
        )
        let report = applied.report
        env.installAnalytics.captureInstall(hosts: InstallAnalyticsHosts.from(report.slots))
        return report
    }

    static func uninstall(_ env: SetupEnvironment) throws(SetupApplyError) -> UninstallReport {
        let files = FileOps(fileManager: env.fileManager)
        let layout = OwnedPaths(home: env.home)
        let installations: HostAdapterInstallationSnapshot
        do {
            installations = try HostAdapterInstallation.inspect(
                paths: layout,
                pathEntries: env.pathEntries,
                fileManager: env.fileManager
            )
        } catch {
            throw .inspectFailed
        }

        let hosts = UninstallHostPlans(layout: layout, installations: installations)
        let launchAgentExisted = files.fileExists(layout.launchAgent)
        let binariesExisted = files.fileExists(layout.localRv) || files.fileExists(layout.localRvd)
        let configDir = URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        let analytics = AnalyticsPaths(configDirectory: configDir)
        let configArtifacts =
            analytics.uninstallArtifacts + RVPolicyPaths.uninstallArtifacts(inConfigDir: configDir)
        let configExisted = configArtifacts.contains { files.fileExists($0.path) }

        let removedPaths =
            hosts.destinationsToRemove
            + [layout.launchAgent, layout.localRv, layout.localRvd]
            + configArtifacts.map(\.path)

        for path in removedPaths {
            files.removeFile(atPath: path)
        }
        files.removeDirectoryIfEmpty(atPath: layout.configDirectory)

        if env.touchLaunchd {
            do {
                try env.launchctl.bootout(domain: "gui/\(getuid())", label: SetupRun.launchAgentLabel)
            } catch {
                throw .launchAgentUnloadFailed
            }
        }

        if removedPaths.contains(where: { files.fileExists($0) }) {
            throw .leftoverOwnedPath
        }

        return UninstallReport(
            removedHosts: hosts.removed,
            occupiedHosts: hosts.occupied,
            removedLaunchAgent: launchAgentExisted,
            removedBinaries: binariesExisted,
            removedConfigArtifacts: configExisted
        )
    }

    private static func applyHosts(
        layout: OwnedPaths,
        installations: HostAdapterInstallationSnapshot,
        env: SetupEnvironment,
        force: Bool,
        files: FileOps
    ) throws -> AppliedSlots {
        func apply(_ host: SetupHostKind) throws -> AppliedSlot {
            let owned = layout.hostAdapter(for: host)
            return try applySlot(
                owned,
                plan: installations.installation(for: host).setupPlan(force: force),
                env: env,
                files: files
            )
        }
        return AppliedSlots(
            grok: try apply(.grok),
            pi: try apply(.pi),
            openCode: try apply(.openCode)
        )
    }

    private static func applySlot(
        _ owned: OwnedHostAdapterPath,
        plan: HostAdapterSetupPlan,
        env: SetupEnvironment,
        files: FileOps
    ) throws -> AppliedSlot {
        switch plan {
        case .skipUndetected:
            return .pending
        case .skipOccupied:
            return .occupied
        case .forceClearThenWrite:
            try files.backupAndClearOwnedPath(owned.destination)
            return try writeWired(owned, existingData: nil, env: env, files: files)
        case .write(let existingData):
            return try writeWired(owned, existingData: existingData, env: env, files: files)
        }
    }

    private static func writeWired(
        _ owned: OwnedHostAdapterPath,
        existingData: Data?,
        env: SetupEnvironment,
        files: FileOps
    ) throws -> AppliedSlot {
        let adapter = try HostAdapterResources.load(for: owned.hookHost)
        let wrote = try writeOwned(
            path: owned.destination,
            contents: adapter.rendered(rvPath: env.rvPath),
            existingData: existingData,
            files: files
        )
        return .wired(wrote: wrote)
    }

    private static func writeLaunchAgent(env: SetupEnvironment, layout: OwnedPaths, files: FileOps) throws {
        guard env.fileManager.isExecutableFile(atPath: env.rvdPath) else {
            return
        }
        let body = try LaunchAgentTemplate.rendered(rvdPath: env.rvdPath)
        try files.write(body, to: layout.launchAgent)
        if env.touchLaunchd {
            let url = URL(fileURLWithPath: layout.launchAgent)
            try? env.launchctl.bootout(domain: "gui/\(getuid())", label: SetupRun.launchAgentLabel)
            try env.launchctl.bootstrap(domain: "gui/\(getuid())", plist: url)
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

private enum AppliedSlot: Equatable, Sendable {
    case pending
    case occupied
    case wired(wrote: Bool)

    var kind: SetupSlotKind {
        switch self {
        case .pending: .pending
        case .occupied: .occupied
        case .wired: .wired
        }
    }

    var wrote: Bool {
        switch self {
        case .wired(true): true
        case .pending, .occupied, .wired(false): false
        }
    }
}

private struct AppliedSlots: Equatable, Sendable {
    let grok: AppliedSlot
    let pi: AppliedSlot
    let openCode: AppliedSlot

    func slot(for host: SetupHostKind) -> AppliedSlot {
        switch host {
        case .grok: grok
        case .pi: pi
        case .openCode: openCode
        }
    }

    var report: SetupReport {
        SetupReport(
            grok: grok.kind,
            pi: pi.kind,
            openCode: openCode.kind,
            wrote: Set(SetupHostKind.allCases.filter { slot(for: $0).wrote })
        )
    }
}

private struct UninstallHostPlans: Equatable, Sendable {
    let removed: Set<SetupHostKind>
    let occupied: Set<SetupHostKind>
    let destinationsToRemove: [String]

    init(layout: OwnedPaths, installations: HostAdapterInstallationSnapshot) {
        var removed: Set<SetupHostKind> = []
        var occupied: Set<SetupHostKind> = []
        var destinationsToRemove: [String] = []
        for owned in layout.hostAdapters {
            switch installations.installation(for: owned.host).uninstallPlan {
            case .remove:
                removed.insert(owned.host)
                destinationsToRemove.append(owned.destination)
            case .leaveOccupied:
                occupied.insert(owned.host)
            case .skip:
                break
            }
        }
        self.removed = removed
        self.occupied = occupied
        self.destinationsToRemove = destinationsToRemove
    }
}

private struct FileOps {
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

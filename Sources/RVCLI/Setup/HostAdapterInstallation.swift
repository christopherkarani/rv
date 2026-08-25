import Foundation
import RVDomain
import RVHooks
import RVPresentation

/// Inspected Host adapter path, including bytes needed to rewrite owned files.
enum HostAdapterInstallation: Equatable, Sendable {
    case missing(OwnedHostAdapterPath)
    case absentFile(OwnedHostAdapterPath)
    case occupied(OwnedHostAdapterPath)
    case broken(path: OwnedHostAdapterPath, existingData: Data)
    case wired(path: OwnedHostAdapterPath, existingData: Data)

    /// What setup should do for this installation, given `--force`.
    func setupPlan(force: Bool) -> HostAdapterSetupPlan {
        switch self {
        case .missing:
            .skipUndetected
        case .occupied:
            force ? .forceClearThenWrite : .skipOccupied
        case .absentFile:
            .write(existingData: nil)
        case .broken(_, let data), .wired(_, let data):
            .write(existingData: data)
        }
    }

    /// What uninstall should do for this installation.
    var uninstallPlan: HostAdapterUninstallPlan {
        switch self {
        case .broken, .wired:
            .remove
        case .occupied:
            .leaveOccupied
        case .missing, .absentFile:
            .skip
        }
    }

    /// Doctor / setup-facing installation state for this path.
    var state: DoctorHostState {
        switch self {
        case .missing:
            .missing
        case .absentFile:
            .absentFile
        case .occupied:
            .occupied
        case .broken:
            .broken
        case .wired:
            .wired
        }
    }
}

enum HostAdapterSetupPlan: Equatable, Sendable {
    case skipUndetected
    case skipOccupied
    case forceClearThenWrite
    case write(existingData: Data?)
}

enum HostAdapterUninstallPlan: Equatable, Sendable {
    case remove
    case leaveOccupied
    case skip
}

/// Closed snapshot of installation state for every v1 Host.
struct HostAdapterInstallationSnapshot: Equatable, Sendable {
    private var grok: HostAdapterInstallation
    private var pi: HostAdapterInstallation
    private var openCode: HostAdapterInstallation

    init(
        grok: HostAdapterInstallation,
        pi: HostAdapterInstallation,
        openCode: HostAdapterInstallation
    ) {
        self.grok = grok
        self.pi = pi
        self.openCode = openCode
    }

    /// Returns the doctor-facing state for `host`.
    func state(for host: HookHost) -> DoctorHostState {
        installation(for: host).state
    }

    /// Returns the full installation record for `host`.
    func installation(for host: HookHost) -> HostAdapterInstallation {
        switch host {
        case .grok:
            grok
        case .pi:
            pi
        case .opencode:
            openCode
        }
    }
}

extension HostAdapterInstallation {
    /// Inspects every owned Host adapter path under `paths` without mutating the filesystem.
    static func inspect(
        paths: OwnedPaths,
        pathEntries: [String],
        fileManager: FileManager
    ) throws -> HostAdapterInstallationSnapshot {
        HostAdapterInstallationSnapshot(
            grok: try inspect(
                path: paths.hostAdapter(for: .grok),
                pathEntries: pathEntries,
                fileManager: fileManager
            ),
            pi: try inspect(
                path: paths.hostAdapter(for: .pi),
                pathEntries: pathEntries,
                fileManager: fileManager
            ),
            openCode: try inspect(
                path: paths.hostAdapter(for: .opencode),
                pathEntries: pathEntries,
                fileManager: fileManager
            )
        )
    }

    private static func inspect(
        path: OwnedHostAdapterPath,
        pathEntries: [String],
        fileManager: FileManager
    ) throws -> HostAdapterInstallation {
        guard isDetected(path, pathEntries: pathEntries, fileManager: fileManager) else {
            return .missing(path)
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: path.destination)) != nil {
            return .occupied(path)
        }
        guard fileManager.fileExists(atPath: path.destination) else {
            return .absentFile(path)
        }
        guard let data = fileManager.contents(atPath: path.destination),
              let text = String(data: data, encoding: .utf8)
        else {
            return .occupied(path)
        }

        let adapter = try HostAdapterResources.load(for: path.host)
        guard let bakedRvPath = adapter.bakedRvPath(in: text) else {
            return .occupied(path)
        }
        let wired = bakedRvPath.isEmpty == false
            && bakedRvPath.hasPrefix("/")
            && fileManager.isExecutableFile(atPath: bakedRvPath)
        if wired {
            return .wired(path: path, existingData: data)
        }
        return .broken(path: path, existingData: data)
    }

    private static func isDetected(
        _ path: OwnedHostAdapterPath,
        pathEntries: [String],
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path.detectionDirectory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return true
        }
        return pathEntries.contains { entry in
            fileManager.isExecutableFile(atPath: entry + "/" + path.executableName)
        }
    }
}

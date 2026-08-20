import Foundation
import RVHooks
import RVPresentation

enum HostAdapterInstallationState: String, Equatable, Sendable {
    case missing
    case absentFile = "absent-file"
    case occupied
    case broken
    case wired
}

enum HostAdapterInstallation: Equatable, Sendable {
    case missing(OwnedHostAdapterPath)
    case absentFile(OwnedHostAdapterPath)
    case occupied(OwnedHostAdapterPath)
    case broken(path: OwnedHostAdapterPath, existingData: Data, bakedRvPath: String)
    case wired(path: OwnedHostAdapterPath, existingData: Data, bakedRvPath: String)

    var state: HostAdapterInstallationState {
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

    func state(for host: SetupHostKind) -> HostAdapterInstallationState {
        installation(for: host).state
    }

    func installation(for host: SetupHostKind) -> HostAdapterInstallation {
        switch host {
        case .grok:
            grok
        case .pi:
            pi
        case .openCode:
            openCode
        }
    }
}

extension HostAdapterInstallation {
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
                path: paths.hostAdapter(for: .openCode),
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

        let adapter = try HostAdapterResources.load(for: path.hookHost)
        guard let bakedRvPath = adapter.bakedRvPath(in: text) else {
            return .occupied(path)
        }
        let wired = bakedRvPath.isEmpty == false
            && bakedRvPath.hasPrefix("/")
            && fileManager.isExecutableFile(atPath: bakedRvPath)
        if wired {
            return .wired(path: path, existingData: data, bakedRvPath: bakedRvPath)
        }
        return .broken(path: path, existingData: data, bakedRvPath: bakedRvPath)
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

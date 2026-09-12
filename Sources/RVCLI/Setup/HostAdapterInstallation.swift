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

    /// File-tool door on this Host adapter. `companionJSON` is Cursor `hooks.json`.
    func fileTools(companionJSON: Data? = nil) -> DoctorFileToolsState {
        switch ownedPath.host {
        case .pi, .opencode, .openclaw, .hermes, .codex:
            return .notApplicable
        case .claude, .cursor, .grok:
            break
        }
        guard case .wired(_, let data) = self else {
            return .notApplicable
        }
        switch ownedPath.host {
        case .claude:
            guard let root = jsonObject(data),
                  ClaudeSettingsMerge.hasFileToolMatchers(in: root)
            else {
                return .shellOnly
            }
            return .wired
        case .grok:
            return GrokHookInspect.hasFileToolDoor(in: data) ? .wired : .shellOnly
        case .cursor:
            guard let companionJSON,
                  let root = jsonObject(companionJSON),
                  CursorHooksMerge.hasFileToolEntry(in: root)
            else {
                return .shellOnly
            }
            return .wired
        case .pi, .opencode, .openclaw, .hermes, .codex:
            return .notApplicable
        }
    }

    private var ownedPath: OwnedHostAdapterPath {
        switch self {
        case .missing(let path), .absentFile(let path), .occupied(let path):
            path
        case .broken(path: let path, _), .wired(path: let path, _):
            path
        }
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

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
    private var claude: HostAdapterInstallation
    private var openClaw: HostAdapterInstallation
    private var hermes: HostAdapterInstallation
    private var codex: HostAdapterInstallation
    private var cursor: HostAdapterInstallation
    /// Cursor File tool matchers live in `hooks.json`, not the adapter script.
    private var cursorHooksJSON: Data?

    init(
        grok: HostAdapterInstallation,
        pi: HostAdapterInstallation,
        openCode: HostAdapterInstallation,
        claude: HostAdapterInstallation,
        openClaw: HostAdapterInstallation,
        hermes: HostAdapterInstallation,
        codex: HostAdapterInstallation,
        cursor: HostAdapterInstallation,
        cursorHooksJSON: Data? = nil
    ) {
        self.grok = grok
        self.pi = pi
        self.openCode = openCode
        self.claude = claude
        self.openClaw = openClaw
        self.hermes = hermes
        self.codex = codex
        self.cursor = cursor
        self.cursorHooksJSON = cursorHooksJSON
    }

    /// Returns the doctor-facing state for `host`.
    func state(for host: HookHost) -> DoctorHostState {
        installation(for: host).state
    }

    /// File-tool door for `host`. Doctor consumes this; it does not re-parse adapter bytes.
    func fileTools(for host: HookHost) -> DoctorFileToolsState {
        installation(for: host).fileTools(
            companionJSON: host == .cursor ? cursorHooksJSON : nil
        )
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
        case .claude:
            claude
        case .openclaw:
            openClaw
        case .hermes:
            hermes
        case .codex:
            codex
        case .cursor:
            cursor
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
            ),
            claude: try inspect(
                path: paths.hostAdapter(for: .claude),
                pathEntries: pathEntries,
                fileManager: fileManager
            ),
            openClaw: try inspect(
                path: paths.hostAdapter(for: .openclaw),
                pathEntries: pathEntries,
                fileManager: fileManager
            ),
            hermes: try inspect(
                path: paths.hostAdapter(for: .hermes),
                pathEntries: pathEntries,
                fileManager: fileManager
            ),
            codex: try inspect(
                path: paths.hostAdapter(for: .codex),
                pathEntries: pathEntries,
                fileManager: fileManager
            ),
            cursor: try inspect(
                path: paths.hostAdapter(for: .cursor),
                pathEntries: pathEntries,
                fileManager: fileManager
            ),
            cursorHooksJSON: fileManager.contents(atPath: paths.cursorHooksJSON)
        )
    }

    private static func inspect(
        path: OwnedHostAdapterPath,
        pathEntries: [String],
        fileManager: FileManager
    ) throws -> HostAdapterInstallation {
        if path.host == .claude {
            return try inspectClaude(path: path, pathEntries: pathEntries, fileManager: fileManager)
        }
        return try inspectExclusive(path: path, pathEntries: pathEntries, fileManager: fileManager)
    }

    private static func inspectClaude(
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
        guard let data = fileManager.contents(atPath: path.destination) else {
            return .occupied(path)
        }

        switch ClaudeSettingsMerge.inspectionState(of: data) {
        case .absentFile:
            return .absentFile(path)
        case .occupied:
            return .occupied(path)
        case .outdated:
            return .broken(path: path, existingData: data)
        case .wired(let bakedPath):
            let executable = bakedPath.isEmpty == false
                && bakedPath.hasPrefix("/")
                && fileManager.isExecutableFile(atPath: bakedPath)
            if executable {
                return .wired(path: path, existingData: data)
            }
            return .broken(path: path, existingData: data)
        }
    }

    private static func inspectExclusive(
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

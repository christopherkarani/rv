import Foundation
import RVDomain

/// One host attach already named by the artifact table. The executor folds this;
/// it does not recover Claude-vs-other write policy from `HookHost`.
struct HostAttachWrite: Equatable, Sendable {
    var host: HookHost
    var destination: String
    var existing: HostExistingData
    var prelude: HostAttachPrelude
    var adapter: HostAdapterWrite
    var companions: [HostCompanionWrite]
}

enum HostAttachPrelude: Equatable, Sendable {
    case none
    /// Occupied exclusive file: move it aside, then write with empty existing bytes.
    case backupAndClearOwnedPath
    /// Occupied Claude settings symlink: do not follow or replace; mark occupied.
    case occupiedIfDestinationSymlink
}

enum HostExistingData: Equatable, Sendable {
    case use(Data?)
    case useOrReread(Data?)
    case reread
    case noneAfterClear
}

enum HostAdapterWrite: Equatable, Sendable {
    case writeOwnedRendered
    case applyGrokThenWriteOwned
    case claudeSettingsMerge(force: Bool)
}

enum HostCompanionWrite: Equatable, Sendable {
    case pluginManifest(path: String)
    case packageManifest(path: String)
    case openCodeTuiPlugin(path: String)
    case openCodeAskPackage
    case codexHooksJSON(adapterPath: String, hooksPath: String)
    case cursorHooksJSON(adapterPath: String, hooksPath: String)
}

/// Inverse of one attach row. The executor folds this; it does not recover
/// OpenClaw-vs-Codex companion lists from `HookHost`.
struct HostDetachWrite: Equatable, Sendable {
    var host: HookHost
    var remove: [HostDetachOperation]
    var leaveOccupied: [HostDetachOperation]
    var alwaysEmptyDirectories: [String]
    var removedOnlyWhenChanged: Bool
}

enum HostDetachOperation: Equatable, Sendable {
    case removeFile(String)
    case removeClaudeRVHooks(String)
    case stripClaudeFingerprintLeavingOccupied(String)
    case removeCodexRVHooks(String)
    case removeCursorRVHooks(String)
    case stripOpenCodeAskPlugin
    case removeEmptyDirectory(String)
}

/// Exhaustive attach recipe for every `HookHost`. Adding a host is a new row here,
/// not a new branch in interpret or a per-host strategy type.
enum HostArtifacts {
    static func attach(
        host: HookHost,
        layout: OwnedPaths,
        existingData: Data?,
        forceClear: Bool
    ) -> HostAttachWrite {
        let destination = layout.hostAdapter(for: host).destination
        let row = row(for: host, destination: destination)
        let adapter: HostAdapterWrite
        switch row.kind {
        case .writeOwnedRendered:
            adapter = .writeOwnedRendered
        case .applyGrokThenWriteOwned:
            adapter = .applyGrokThenWriteOwned
        case .claudeSettingsMerge:
            adapter = .claudeSettingsMerge(force: forceClear)
        }
        if forceClear {
            let existing: HostExistingData
            switch row.forcePrelude {
            case .backupAndClearOwnedPath:
                existing = .noneAfterClear
            case .occupiedIfDestinationSymlink:
                existing = .reread
            case .none:
                existing = .use(existingData)
            }
            return HostAttachWrite(
                host: host,
                destination: destination,
                existing: existing,
                prelude: row.forcePrelude,
                adapter: adapter,
                companions: row.companions
            )
        }
        let existing: HostExistingData
        switch row.kind {
        case .claudeSettingsMerge:
            existing = .useOrReread(existingData)
        case .writeOwnedRendered, .applyGrokThenWriteOwned:
            existing = .use(existingData)
        }
        return HostAttachWrite(
            host: host,
            destination: destination,
            existing: existing,
            prelude: .none,
            adapter: adapter,
            companions: row.companions
        )
    }

    /// Inverse of `attach` for the same row. Adding a host still means one table row.
    static func detach(host: HookHost, layout: OwnedPaths) -> HostDetachWrite {
        let destination = layout.hostAdapter(for: host).destination
        let row = row(for: host, destination: destination)
        var remove: [HostDetachOperation] = []
        var leaveOccupied: [HostDetachOperation] = []
        let removedOnlyWhenChanged: Bool
        switch row.kind {
        case .writeOwnedRendered, .applyGrokThenWriteOwned:
            remove.append(.removeFile(destination))
            removedOnlyWhenChanged = false
        case .claudeSettingsMerge:
            remove.append(.removeClaudeRVHooks(destination))
            leaveOccupied.append(.stripClaudeFingerprintLeavingOccupied(destination))
            removedOnlyWhenChanged = true
        }
        for companion in row.companions {
            remove.append(contentsOf: invert(companion, layout: layout))
        }
        return HostDetachWrite(
            host: host,
            remove: remove,
            leaveOccupied: leaveOccupied,
            alwaysEmptyDirectories: row.emptyDirectories,
            removedOnlyWhenChanged: removedOnlyWhenChanged
        )
    }

    private static func invert(
        _ companion: HostCompanionWrite,
        layout: OwnedPaths
    ) -> [HostDetachOperation] {
        switch companion {
        case .pluginManifest(let path), .packageManifest(let path), .openCodeTuiPlugin(let path):
            return [.removeFile(path)]
        case .openCodeAskPackage:
            return [
                .removeFile(layout.openCodeTuiAskPackage + "/package.json"),
                .removeFile(layout.openCodeTuiAskPackage + "/tui.js"),
                .stripOpenCodeAskPlugin,
                .removeEmptyDirectory(layout.openCodeTuiAskPackage),
            ]
        case .codexHooksJSON(_, let hooksPath):
            return [.removeCodexRVHooks(hooksPath)]
        case .cursorHooksJSON(_, let hooksPath):
            return [.removeCursorRVHooks(hooksPath)]
        }
    }

    private enum AdapterKind {
        case writeOwnedRendered
        case applyGrokThenWriteOwned
        case claudeSettingsMerge
    }

    private struct Row {
        var kind: AdapterKind
        var companions: [HostCompanionWrite]
        var forcePrelude: HostAttachPrelude
        var emptyDirectories: [String]
    }

    private static func row(for host: HookHost, destination: String) -> Row {
        let directory = (destination as NSString).deletingLastPathComponent
        switch host {
        case .grok:
            return Row(
                kind: .applyGrokThenWriteOwned,
                companions: [],
                forcePrelude: .backupAndClearOwnedPath,
                emptyDirectories: []
            )
        case .pi:
            return Row(
                kind: .writeOwnedRendered,
                companions: [],
                forcePrelude: .backupAndClearOwnedPath,
                emptyDirectories: []
            )
        case .opencode:
            return Row(
                kind: .writeOwnedRendered,
                companions: [
                    .openCodeTuiPlugin(path: directory + "/rv-guard-tui.js"),
                    .openCodeAskPackage,
                ],
                forcePrelude: .backupAndClearOwnedPath,
                emptyDirectories: []
            )
        case .claude:
            return Row(
                kind: .claudeSettingsMerge,
                companions: [],
                forcePrelude: .occupiedIfDestinationSymlink,
                emptyDirectories: []
            )
        case .openclaw:
            return Row(
                kind: .writeOwnedRendered,
                companions: [
                    .pluginManifest(path: directory + "/openclaw.plugin.json"),
                    .packageManifest(path: directory + "/package.json"),
                ],
                forcePrelude: .backupAndClearOwnedPath,
                emptyDirectories: [directory]
            )
        case .hermes:
            return Row(
                kind: .writeOwnedRendered,
                companions: [
                    .pluginManifest(path: directory + "/plugin.yaml"),
                ],
                forcePrelude: .backupAndClearOwnedPath,
                emptyDirectories: [directory]
            )
        case .codex:
            return Row(
                kind: .writeOwnedRendered,
                companions: [
                    .codexHooksJSON(
                        adapterPath: directory + "/rv-guard.py",
                        hooksPath: (directory as NSString).deletingLastPathComponent + "/hooks.json"
                    ),
                ],
                forcePrelude: .backupAndClearOwnedPath,
                emptyDirectories: [directory]
            )
        case .cursor:
            return Row(
                kind: .writeOwnedRendered,
                companions: [
                    .cursorHooksJSON(
                        adapterPath: directory + "/rv-guard.py",
                        hooksPath: (directory as NSString).deletingLastPathComponent + "/hooks.json"
                    ),
                ],
                forcePrelude: .backupAndClearOwnedPath,
                emptyDirectories: [directory]
            )
        }
    }
}

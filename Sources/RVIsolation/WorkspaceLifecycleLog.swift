#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// One line in the workspace lifecycle log.
///
/// A `created` line without a later `closed` line means the workspace was
/// still open when the log was last written. This chunk does not scan that
/// log on startup, republish, or unmount. The line is enough for a later
/// recovery tool to find the id, the original path, the protected path, and
/// the volume that was mounted.
struct WorkspaceLifecycleRecord: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case created
        case runtimeEnded
        case closed
    }

    var kind: Kind
    var workspace: UUID
    var originalPath: String
    var protectedPath: String
    var volumeDevice: UInt64?
    var disk: String?
    var runtime: UUID?
    var recordedAt: Date
}

/// Append-only workspace lifetime log. Not the denial ledger.
struct WorkspaceLifecycleStore: Sendable {
    var append: @Sendable (WorkspaceLifecycleRecord) -> Result<Void, IsolationApplyError>

    static let production = WorkspaceLifecycleStore { record in
        guard let url = WorkspaceLifecycleLog.productionURL() else {
            return .failure(.sessionRecordFailed)
        }
        return WorkspaceLifecycleLog.append(record, to: url)
    }

    static func file(_ url: URL) -> WorkspaceLifecycleStore {
        WorkspaceLifecycleStore { record in
            WorkspaceLifecycleLog.append(record, to: url)
        }
    }
}

enum WorkspaceLifecycleLog {
    private struct Encoded: Codable {
        var kind: String
        var workspace: UUID
        var originalPath: String
        var protectedPath: String
        var volumeDevice: UInt64?
        var disk: String?
        var runtime: UUID?
        var recordedAt: Double
    }

    /// `$HOME/.config/rv/workspace-sessions.jsonl`. Ignores `XDG_CONFIG_HOME`.
    static func productionURL() -> URL? {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
            home.hasPrefix("/"), home.contains("\0") == false
        else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("workspace-sessions.jsonl", isDirectory: false)
    }

    static func append(
        _ record: WorkspaceLifecycleRecord,
        to url: URL
    ) -> Result<Void, IsolationApplyError> {
        let encoded = Encoded(
            kind: record.kind.rawValue,
            workspace: record.workspace,
            originalPath: record.originalPath,
            protectedPath: record.protectedPath,
            volumeDevice: record.volumeDevice,
            disk: record.disk,
            runtime: record.runtime,
            recordedAt: record.recordedAt.timeIntervalSince1970
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(encoded) else {
            return .failure(.sessionRecordFailed)
        }
        data.append(UInt8(ascii: "\n"))
        return RuntimeSessionLog.appendExclusiveLine(data, to: url)
    }

    static func records(at url: URL) -> [WorkspaceLifecycleRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var decoded: [WorkspaceLifecycleRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                let record = try? decoder.decode(Encoded.self, from: data),
                let kind = WorkspaceLifecycleRecord.Kind(rawValue: record.kind)
            else {
                continue
            }
            decoded.append(
                WorkspaceLifecycleRecord(
                    kind: kind,
                    workspace: record.workspace,
                    originalPath: record.originalPath,
                    protectedPath: record.protectedPath,
                    volumeDevice: record.volumeDevice,
                    disk: record.disk,
                    runtime: record.runtime,
                    recordedAt: Date(timeIntervalSince1970: record.recordedAt)
                )
            )
        }
        return decoded
    }
}

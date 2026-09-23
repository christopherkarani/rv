#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Identities needed to prove a protected workspace still belongs to RV.
///
/// These are not live file descriptors or mount objects. Recovery uses them
/// to decide whether a directory, lock, image, or mount is the one this
/// workspace created.
struct WorkspaceDurableIdentity: Equatable, Sendable, Codable {
    var savedPath: String
    var savedDevice: UInt64
    var savedInode: UInt64
    var quarantinePath: String
    var volumeDevice: UInt64
    var disk: String
    var mountSource: String
    var imagePath: String?
    var imageDevice: UInt64?
    var imageInode: UInt64?
    var lockPath: String
    var lockDevice: UInt64
    var lockInode: UInt64
    var ownerToken: UUID
    var snapshotPath: String
    var snapshotDevice: UInt64
    var snapshotInode: UInt64
}

/// One line in the workspace lifecycle log.
struct WorkspaceLifecycleRecord: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case created
        case runtimeStarted
        case runtimeEnded
        case recoveryBegan
        case childTeardownCompleted
        case publicationCompleted
        case mountCleanupCompleted
        case originalRestored
        case recoveryCompleted
        case recoveryBlocked
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
    var identity: WorkspaceDurableIdentity?
    var processGroup: Int64?
    var processStartSeconds: Int64?
    var processStartMicroseconds: Int64?
    var blockReason: String?

    init(
        kind: Kind,
        workspace: UUID,
        originalPath: String,
        protectedPath: String,
        volumeDevice: UInt64?,
        disk: String?,
        runtime: UUID?,
        recordedAt: Date,
        identity: WorkspaceDurableIdentity? = nil,
        processGroup: Int64? = nil,
        processStartSeconds: Int64? = nil,
        processStartMicroseconds: Int64? = nil,
        blockReason: String? = nil
    ) {
        self.kind = kind
        self.workspace = workspace
        self.originalPath = originalPath
        self.protectedPath = protectedPath
        self.volumeDevice = volumeDevice
        self.disk = disk
        self.runtime = runtime
        self.recordedAt = recordedAt
        self.identity = identity
        self.processGroup = processGroup
        self.processStartSeconds = processStartSeconds
        self.processStartMicroseconds = processStartMicroseconds
        self.blockReason = blockReason
    }
}

/// Append-only workspace lifetime log. Not the denial ledger.
struct WorkspaceLifecycleStore: Sendable {
    var append: @Sendable (WorkspaceLifecycleRecord) -> Result<Void, IsolationApplyError>
    /// File recovery reads. Nil when the home directory cannot be named.
    var file: URL?

    static let production: WorkspaceLifecycleStore = {
        let url = WorkspaceLifecycleLog.productionURL()
        return WorkspaceLifecycleStore(
            append: { record in
                guard let url = WorkspaceLifecycleLog.productionURL() else {
                    return .failure(.sessionRecordFailed)
                }
                return WorkspaceLifecycleLog.append(record, to: url)
            },
            file: url
        )
    }()

    static func file(_ url: URL) -> WorkspaceLifecycleStore {
        WorkspaceLifecycleStore(
            append: { record in
                WorkspaceLifecycleLog.append(record, to: url)
            },
            file: url
        )
    }
}

struct WorkspaceLogRead: Equatable, Sendable {
    var records: [WorkspaceLifecycleRecord]
    /// The last line is not a complete record. Earlier records are kept.
    var tornTrailing: Bool
    /// A non-trailing line could not be decoded. The sequence is not trustworthy.
    var interiorCorruption: Bool
}

enum WorkspaceLogLoad: Equatable, Sendable {
    case missing
    case unreadable
    case decoded(WorkspaceLogRead)
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
        var identity: WorkspaceDurableIdentity?
        var processGroup: Int64?
        var processStartSeconds: Int64?
        var processStartMicroseconds: Int64?
        var blockReason: String?
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
            recordedAt: record.recordedAt.timeIntervalSince1970,
            identity: record.identity,
            processGroup: record.processGroup,
            processStartSeconds: record.processStartSeconds,
            processStartMicroseconds: record.processStartMicroseconds,
            blockReason: record.blockReason
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
        guard case .decoded(let read) = load(at: url) else { return [] }
        return read.records
    }

    /// Missing file is an empty history. A file that cannot be read is not.
    static func load(at url: URL) -> WorkspaceLogLoad {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists == false {
            return .missing
        }
        if isDirectory.boolValue {
            return .unreadable
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable
        }
        if data.isEmpty {
            return .decoded(WorkspaceLogRead(records: [], tornTrailing: false, interiorCorruption: false))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .decoded(WorkspaceLogRead(records: [], tornTrailing: true, interiorCorruption: false))
        }
        return .decoded(decode(text))
    }

    private static func decode(_ text: String) -> WorkspaceLogRead {
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let decoder = JSONDecoder()
        var records: [WorkspaceLifecycleRecord] = []
        var tornTrailing = false
        var interiorCorruption = false
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            let isLast = index == lines.index(before: lines.endIndex)
            if let record = decodeLine(line, decoder: decoder) {
                records.append(record)
                continue
            }
            if isLast {
                tornTrailing = true
            } else {
                interiorCorruption = true
            }
        }
        return WorkspaceLogRead(
            records: records,
            tornTrailing: tornTrailing,
            interiorCorruption: interiorCorruption
        )
    }

    private static func decodeLine(_ line: String, decoder: JSONDecoder) -> WorkspaceLifecycleRecord? {
        guard let data = line.data(using: .utf8),
            let record = try? decoder.decode(Encoded.self, from: data),
            let kind = WorkspaceLifecycleRecord.Kind(rawValue: record.kind)
        else {
            return nil
        }
        return WorkspaceLifecycleRecord(
            kind: kind,
            workspace: record.workspace,
            originalPath: record.originalPath,
            protectedPath: record.protectedPath,
            volumeDevice: record.volumeDevice,
            disk: record.disk,
            runtime: record.runtime,
            recordedAt: Date(timeIntervalSince1970: record.recordedAt),
            identity: record.identity,
            processGroup: record.processGroup,
            processStartSeconds: record.processStartSeconds,
            processStartMicroseconds: record.processStartMicroseconds,
            blockReason: record.blockReason
        )
    }
}

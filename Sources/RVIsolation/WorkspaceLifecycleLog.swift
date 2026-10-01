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
        /// The persistent host bound its control endpoint. Not proof of liveness.
        case hostStarted
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
    /// Persistent host that bound the control endpoint. Absent on older lines.
    var host: UUID?

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
        blockReason: String? = nil,
        host: UUID? = nil
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
        self.host = host
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

/// Outcome of opportunistic lifecycle-log compaction. Refusals leave the
/// file untouched; compaction must never erase evidence it cannot read.
enum WorkspaceLifecycleCompactResult: Equatable, Sendable {
    /// At or below the threshold; untouched.
    case skippedSmall
    /// Above the threshold but no closed workspace to drop; untouched.
    case skippedNothingDead
    /// Lock, read, or rewrite failed; file may be untouched or, on rewrite
    /// failure, left as it was (rename never ran).
    case refusedUnreadable
    /// Trailing partial line; untouched.
    case refusedTorn
    /// Non-trailing undecodable line, or non-UTF-8 bytes; untouched.
    case refusedCorrupt
    /// Rewrote the file, dropping only closed workspaces' lines.
    case compacted(dropped: Int, kept: Int)
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
        var host: UUID?
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
            blockReason: record.blockReason,
            host: record.host
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

    /// Outcome of opportunistic lifecycle-log compaction.
    static let compactThresholdBytes = 1_048_576

    /// Drops lines of closed workspaces when the log exceeds `thresholdBytes`.
    ///
    /// Recovery filters to open workspaces before every decision, so removing
    /// closed workspaces' lines changes no assessment. Kept lines are
    /// rewritten byte-identical; only dead lines disappear. Refuses (leaving
    /// the file untouched) when the log is torn, corrupt, or unreadable:
    /// compaction must never erase evidence it cannot understand. Runs under
    /// the same cross-process lock as appends, so concurrent appends wait
    /// and then land on the compacted file; lock-free readers see the old or
    /// the new file whole via atomic rename.
    static func compactIfNeeded(
        at url: URL,
        thresholdBytes: Int = compactThresholdBytes
    ) -> WorkspaceLifecycleCompactResult {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        guard let size, size > thresholdBytes else {
            return .skippedSmall
        }
        guard
            let outcome = RuntimeSessionLog.withExclusiveFileLock(at: url, body: { locked in
                compactLocked(at: locked)
            })
        else {
            return .refusedUnreadable
        }
        return outcome
    }

    private static func compactLocked(at url: URL) -> WorkspaceLifecycleCompactResult {
        guard let data = try? Data(contentsOf: url) else {
            return .refusedUnreadable
        }
        if data.isEmpty {
            return .skippedNothingDead
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .refusedCorrupt
        }
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let decoder = JSONDecoder()
        var records: [WorkspaceLifecycleRecord?] = []
        records.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                records.append(nil)
                continue
            }
            guard let record = decodeLine(line, decoder: decoder) else {
                let isLast = index == lines.index(before: lines.endIndex)
                return isLast ? .refusedTorn : .refusedCorrupt
            }
            records.append(record)
        }
        var closedIDs = Set<UUID>()
        for record in records.compactMap({ $0 }) where record.kind == .closed {
            closedIDs.insert(record.workspace)
        }
        if closedIDs.isEmpty {
            return .skippedNothingDead
        }
        var kept: [String] = []
        kept.reserveCapacity(lines.count)
        var dropped = 0
        for (line, record) in zip(lines, records) {
            if let record, closedIDs.contains(record.workspace) {
                dropped += 1
                continue
            }
            kept.append(line)
        }
        if dropped == 0 {
            return .skippedNothingDead
        }
        var output = kept.joined(separator: "\n")
        if endsWithNewline, kept.isEmpty == false {
            output.append("\n")
        }
        guard writeAtomically(Data(output.utf8), to: url) else {
            return .refusedUnreadable
        }
        return .compacted(dropped: dropped, kept: kept.count)
    }

    /// Temp-file + rename rewrite with the same durability shape as endpoint
    /// files: exclusive create, full write, fsync, 0600, atomic rename, then
    /// a directory fsync. Runs under `withExclusiveFileLock`.
    private static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        let temporary = url.appendingPathExtension("tmp")
        _ = temporary.path.withCString { unlink($0) }
        let fd = temporary.path.withCString {
            open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            return false
        }
        var offset = 0
        let bytes = [UInt8](data)
        var wrote = true
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            wrote = false
            break
        }
        if wrote {
            wrote = fsync(fd) == 0 && fchmod(fd, 0o600) == 0
        }
        close(fd)
        guard wrote else {
            _ = temporary.path.withCString { unlink($0) }
            return false
        }
        guard temporary.path.withCString({ source in
            url.path.withCString { destination in
                rename(source, destination) == 0
            }
        }) else {
            _ = temporary.path.withCString { unlink($0) }
            return false
        }
        let parent = url.deletingLastPathComponent().path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        if parent >= 0 {
            _ = fsync(parent)
            close(parent)
        }
        return true
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
            blockReason: record.blockReason,
            host: record.host
        )
    }
}

import Foundation
import RVDomain
import RVFileStore

// MARK: - Shared ledger types

/// The ledger's record wire type, paths, and retention live in
/// `RVFileStore.SecretsLedger` so the broker, the invoker, and this store
/// share one definition without a package cycle. These aliases keep
/// `RVHistory`'s public API source-compatible: every name below is the
/// same type, not a copy.

/// Primary audit key for one secrets/MCP execution (T0c ID taxonomy).
public typealias SecretsExecutionID = RVFileStore.SecretsExecutionID
/// Error-linkage id (T0c ID taxonomy).
public typealias SecretsCorrelationID = RVFileStore.SecretsCorrelationID
/// Labels-only principal for one audit row.
public typealias SecretsAuditPrincipal = RVFileStore.SecretsAuditPrincipal
/// Closed audit-event vocabulary. Wire names per spec section 4.5.
public typealias SecretsAuditKind = RVFileStore.SecretsAuditKind
/// Labels-only audit target: a secret label triple or a tool address.
public typealias SecretsAuditAddressOrRef = RVFileStore.SecretsAuditAddressOrRef
/// Closed decision vocabulary across all four audit kinds.
public typealias SecretsAuditDecision = RVFileStore.SecretsAuditDecision
/// Redacted free-text cause for one audit row.
public typealias SecretsAuditCause = RVFileStore.SecretsAuditCause
/// One labels-only audit row (spec section 4.5).
public typealias SecretsAuditRecord = RVFileStore.SecretsAuditRecord
/// Ledger file layout beside `blocks.jsonl`.
public typealias SecretsAuditPaths = RVFileStore.SecretsAuditPaths
/// Deployment-tunable retention (COM-001: duration is deployment policy).
public typealias SecretsAuditRetention = RVFileStore.SecretsAuditRetention
/// Fail-closed append failures. Callers deny the audited operation.
public typealias SecretsAuditError = RVFileStore.SecretsLedgerError

/// Opaque caller-visible defect (REQ-015, AC-010).
///
/// Callers see only the correlation id; the cause stays server-side on the
/// audit row with the same id.
public enum SecretsAuditOpaqueDefect {
    /// Formats the caller-visible defect for one correlation id.
    public static func message(correlationID: SecretsCorrelationID) -> String {
        "Internal tool error [\(correlationID.rawValue.uuidString)]"
    }

    /// Recovers the correlation id from a defect message. Nil unless the
    /// message holds exactly one bracketed UUID.
    public static func correlationID(from message: String) -> SecretsCorrelationID? {
        guard let open = message.firstIndex(of: "["),
              let close = message[message.index(after: open)...].firstIndex(of: "]")
        else {
            return nil
        }
        let inner = String(message[message.index(after: open)..<close])
        guard inner.contains("[") == false, inner.contains("]") == false else {
            return nil
        }
        let before = message[..<open]
        let after = message[message.index(after: close)...]
        guard before.contains("[") == false, before.contains("]") == false,
              after.contains("[") == false, after.contains("]") == false
        else {
            return nil
        }
        return SecretsCorrelationID(validating: inner)
    }
}

/// Joins one audit execution to its `PendingApprovalStore` row.
///
/// The store key for an execution is the execution id rendered as an
/// `ApprovalID`: T4/T8 create the pending row under that key, park via the
/// existing `askBackend`, and append audit rows here. The pending record
/// itself lives only in the store; this ledger never duplicates it.
public struct SecretsAuditApprovalLink: Sendable, Equatable, Hashable {
    /// Execution the audit rows belong to.
    public var executionID: SecretsExecutionID
    /// Store key of the pending row.
    public var approvalID: ApprovalID

    /// Links an execution to its store row. Nil unless the store key names
    /// this execution: a mismatched join fails closed instead of binding
    /// the wrong wait.
    public init?(executionID: SecretsExecutionID, approval: PendingApproval) {
        guard approval.id.rawValue == executionID.rawValue.uuidString else {
            return nil
        }
        self.executionID = executionID
        self.approvalID = approval.id
    }

    /// The `PendingApprovalStore` key T4/T8 create for this execution.
    public static func storeKey(for executionID: SecretsExecutionID) -> ApprovalID {
        ApprovalID(rawValue: executionID.rawValue.uuidString)
    }
}

/// Durable secrets/MCP audit ledger on the shared `SecretsLedger` writer.
///
/// Appends fail closed with `SecretsAuditError`: T4/T8 deny the audited
/// operation when the write fails. Reads fail open to `[]`, mirroring
/// `DenialLedger`. Files are owner-only (0600 rows, 0700 directory) via the
/// shared writer's at-fd protocol.
public struct SecretsAuditStore: Sendable {
    /// Hot ledger rows file. Always the canonical `secrets-audit.jsonl`
    /// basename: writes resolve through the directory, so a custom
    /// basename would split reads from writes.
    public private(set) var fileURL: URL
    /// Deployment retention enforced on every write.
    public var retention: SecretsAuditRetention

    /// Creates a store for `<configDirectory>/secrets-audit.jsonl`.
    public init(configDirectory: URL, retention: SecretsAuditRetention = .default) {
        self.init(
            fileURL: SecretsAuditPaths(configDirectory: configDirectory).fileURL,
            retention: retention
        )
    }

    /// Creates a store for one rows file. Test seam for isolated ledgers:
    /// isolate by directory, not by filename. Traps unless `fileURL`
    /// names the canonical `secrets-audit.jsonl` basename.
    public init(fileURL: URL, retention: SecretsAuditRetention = .default) {
        precondition(
            fileURL.lastPathComponent == SecretsAuditPaths.fileName,
            "SecretsAuditStore(fileURL:) requires the canonical secrets-audit.jsonl basename; isolate ledgers by directory"
        )
        self.fileURL = fileURL
        self.retention = retention
    }

    /// Appends one row under the ledger lock with `O_APPEND`.
    ///
    /// Over-budget appends rotate first when generations are configured;
    /// otherwise they throw `.ledgerFull` and leave existing rows untouched.
    /// A row retention would immediately drop (backdated past `maxAge`, or
    /// displaced at the `maxRows` cap) throws `.rowExpired` instead of
    /// reporting a success that persisted nothing.
    /// - Note: Hot appends never rewrite the file, so undecodable lines
    ///   are never deleted by appending: only `purgeExpired` rewrites, and
    ///   it carries unknown bytes forward verbatim.
    public func append(_ record: SecretsAuditRecord, now: Date) throws(SecretsAuditError) {
        try SecretsLedger.append(
            [record],
            directory: directoryURL,
            retention: retention.validated(),
            admissionNow: now
        )
    }

    /// Hot-file rows as of `now`, newest-first after retention.
    ///
    /// - Note: Reads the JSONL file (O(n) in file length). A missing file is empty.
    public func records(asOf now: Date) -> [SecretsAuditRecord] {
        Array(pruned(SecretsLedger.loadRecords(fileURL: fileURL), now: now).reversed())
    }

    /// Hot-file rows for one execution as of `now`, newest-first.
    public func records(for executionID: SecretsExecutionID, asOf now: Date) -> [SecretsAuditRecord] {
        records(asOf: now).filter { $0.executionID == executionID }
    }

    /// Hot plus rotated rows as of `now`, newest-first after retention.
    ///
    /// Reads rotated generations oldest-first without the lock (loads are
    /// torn-tolerant), then prunes the union. Post-hoc review and off-host
    /// ship read here; the hot path reads `records(asOf:)`.
    public func recordsIncludingRotated(asOf now: Date) -> [SecretsAuditRecord] {
        let retention = retention.validated()
        var all: [SecretsAuditRecord] = []
        if retention.maxGenerations > 0 {
            for generation in stride(from: retention.maxGenerations, through: 1, by: -1) {
                all += SecretsLedger.loadRecords(
                    fileURL: paths.rotatedURL(generation: generation)
                )
            }
        }
        all += SecretsLedger.loadRecords(fileURL: fileURL)
        return Array(pruned(all, now: now).reversed())
    }

    /// Rows still inside the age window, oldest-first, capped at `maxRows`
    /// (newest kept). Pure: shared by writes, reads, and tests.
    public func pruned(_ records: [SecretsAuditRecord], now: Date) -> [SecretsAuditRecord] {
        SecretsLedger.pruned(records, now: now, retention: retention.validated())
    }

    /// Rotates the hot file to generation 1 when rotation is configured.
    /// Returns false without touching disk when disabled or when the hot
    /// file is missing.
    @discardableResult
    public func rotate() throws(SecretsAuditError) -> Bool {
        try SecretsLedger.rotate(
            directory: directoryURL,
            retention: retention.validated()
        )
    }

    /// Drops rows outside retention without appending, carrying
    /// undecodable bytes forward verbatim. Recovery path after
    /// ledger-full: stale rows leave, and the next append can fit again.
    public func purgeExpired(now: Date) throws(SecretsAuditError) {
        try SecretsLedger.purgeExpired(
            directory: directoryURL,
            retention: retention.validated(),
            now: now
        )
    }

    /// True when the directory is 0700 and the hot file plus every
    /// rotated generation present is 0600. A missing file reports true:
    /// nothing secret is on disk yet. The lock and temp siblings stay out:
    /// both are 0600 by construction and the temp file is transient.
    public func hasOwnerOnlyPermissions() -> Bool {
        guard posixPermissions(of: directoryURL) == 0o700 else { return false }
        if FileManager.default.fileExists(atPath: fileURL.path),
            posixPermissions(of: fileURL) != 0o600
        {
            return false
        }
        let generations = retention.validated().maxGenerations
        if generations > 0 {
            for generation in 1...generations {
                let url = paths.rotatedURL(generation: generation)
                if FileManager.default.fileExists(atPath: url.path),
                    posixPermissions(of: url) != 0o600
                {
                    return false
                }
            }
        }
        return true
    }

    private var directoryURL: URL {
        fileURL.deletingLastPathComponent()
    }

    private var paths: SecretsAuditPaths {
        SecretsAuditPaths(configDirectory: directoryURL)
    }
}

private func posixPermissions(of url: URL) -> Int? {
    guard let raw = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int else {
        return nil
    }
    return raw & 0o777
}

/// Off-host ship parameters. No IO here: the planner below is pure, and the
/// transport that consumes its lines lands with the deployment.
public struct SecretsAuditShipConfig: Sendable, Equatable {
    /// Ship endpoint. Nil keeps the deployment local-only.
    public var endpoint: URL?
    /// Rows per shipment.
    public var batchSize: Int

    /// Assembles ship parameters. Use `validated()` before planning.
    public init(endpoint: URL?, batchSize: Int) {
        self.endpoint = endpoint
        self.batchSize = batchSize
    }

    /// Local-only deployment: no endpoint, 500-row batches for local review export.
    public static var localOnly: SecretsAuditShipConfig {
        SecretsAuditShipConfig(endpoint: nil, batchSize: 500)
    }

    /// Clamps the batch to 1...1000.
    public func validated() -> SecretsAuditShipConfig {
        SecretsAuditShipConfig(endpoint: endpoint, batchSize: min(max(batchSize, 1), 1000))
    }
}

/// Monotonic cursor over the audit order (timestamp, execution id, kind).
public struct SecretsAuditShipCursor: Sendable, Equatable, Hashable, Codable {
    /// Timestamp of the last shipped row.
    public var timestamp: Date
    /// Execution id of the last shipped row.
    public var executionID: SecretsExecutionID
    /// Kind of the last shipped row.
    public var kind: SecretsAuditKind
    /// Zero-based position of the last shipped row within its equal-key run.
    /// Rows sharing (timestamp, execution id, kind) are common enough (one
    /// dispatch stamping several rows) that the cursor must resume inside
    /// the run instead of skipping its tail. Defaults to zero so cursors
    /// persisted before this field decode unchanged.
    public var duplicateIndex: Int = 0

    /// Assembles a cursor from shipped-row parts.
    public init(
        timestamp: Date, executionID: SecretsExecutionID, kind: SecretsAuditKind,
        duplicateIndex: Int = 0
    ) {
        self.timestamp = timestamp
        self.executionID = executionID
        self.kind = kind
        self.duplicateIndex = duplicateIndex
    }

    /// Cursor after shipping this row.
    public init(record: SecretsAuditRecord, duplicateIndex: Int = 0) {
        self.init(
            timestamp: record.timestamp, executionID: record.executionID, kind: record.kind,
            duplicateIndex: duplicateIndex
        )
    }

    fileprivate func key() -> (Date, String, String) {
        (timestamp, executionID.rawValue.uuidString, kind.rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, executionID, kind, duplicateIndex
    }
}

extension SecretsAuditShipCursor {
    /// Decodes with `duplicateIndex` defaulting to zero, so cursors
    /// persisted before the field existed resume at their run start.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        executionID = try container.decode(SecretsExecutionID.self, forKey: .executionID)
        kind = try container.decode(SecretsAuditKind.self, forKey: .kind)
        duplicateIndex = try container.decodeIfPresent(Int.self, forKey: .duplicateIndex) ?? 0
    }
}

/// One planned shipment: JSONL lines plus the cursor after the last one.
public struct SecretsAuditShipment: Sendable, Equatable {
    /// JSONL lines, oldest-first, labels-only with redacted causes.
    public var lines: [String]
    /// Cursor after the last shipped row. Nil when nothing shipped: the
    /// caller keeps its previous cursor.
    public var nextCursor: SecretsAuditShipCursor?

    /// Assembles one shipment.
    public init(lines: [String], nextCursor: SecretsAuditShipCursor?) {
        self.lines = lines
        self.nextCursor = nextCursor
    }
}

/// Pure off-host shipment planner.
///
/// Sorts oldest-first over the audit order, ships rows strictly after the
/// cursor, and advances the cursor to the last shipped row. Rows sharing
/// the cursor's key resume by `duplicateIndex`, so an equal-key run split
/// across two batches ships its tail instead of skipping it. Callers feed
/// `recordsIncludingRotated(asOf:)` reversed to oldest-first across
/// generations so a rotation never skips or duplicates a row. The sort is
/// stable, so an equal-key run keeps caller order: feeding newest-first
/// (or any unstable order) scrambles run positions against the persisted
/// `duplicateIndex` and can skip or reship rows.
public enum SecretsAuditShipper {
    /// Plans the next shipment after `cursor`. Empty when caught up.
    public static func plan(
        records: [SecretsAuditRecord],
        after cursor: SecretsAuditShipCursor?,
        batchSize: Int
    ) -> SecretsAuditShipment {
        let size = min(max(batchSize, 1), 1000)
        // Keys computed once per row; the sort is stable, so equal keys
        // keep input order and the run index below is deterministic.
        let ordered = records
            .map { (SecretsLedger.orderingKey(of: $0), $0) }
            .sorted { $0.0 < $1.0 }
        let cursorKey = cursor?.key()
        var pending: [(SecretsAuditRecord, Int)] = []
        var previousKey: (Date, String, String)?
        var runIndex = 0
        for (key, record) in ordered {
            if let previousKey, previousKey == key {
                runIndex += 1
            } else {
                runIndex = 0
                previousKey = key
            }
            if let cursor, let cursorKey {
                guard key > cursorKey || (key == cursorKey && runIndex > cursor.duplicateIndex) else {
                    continue
                }
            }
            pending.append((record, runIndex))
        }
        let batch = Array(pending.prefix(size))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lines = batch.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry.0) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return SecretsAuditShipment(
            lines: lines,
            nextCursor: batch.last.map { SecretsAuditShipCursor(record: $0, duplicateIndex: $1) }
        )
    }
}

import Foundation
import RVDomain

/// The audit log could not record a gate change that loosens (or might
/// loosen) the gate, so the change was not made.
public struct ConfigChangeUnrecorded: Error, Sendable, Equatable, CustomStringConvertible {
    public var subject: String

    public init(subject: String) {
        self.subject = subject
    }

    public var description: String {
        "the audit log could not record the \(subject) change, so it was not made "
            + "(check that audit.jsonl in the rv config directory is writable)"
    }
}

/// Audit events for changes to the gate itself: `policy.changed` (a new
/// machine or repo policy revision), `config.changed` (one setting such as
/// safety, a host mode, packs, the allowlist, secret definitions or an
/// egress review) and `policy.managed` (the organization bundle).
///
/// Events name what changed, the revision and content hash where there is
/// one, prior and new values of scalar settings, which way the change moves
/// the gate (`direction`), and how it was authorized. Never secret values,
/// never policy bodies or command text.
///
/// Stores record write-ahead through `commit`: the event lands in the
/// hash-chained `audit.jsonl` before the change is written. When the log
/// cannot take it, enforcement wins over audit completeness: a change that
/// only tightens the gate is still made (with a warning and a late record),
/// and anything else is refused (as the secret gateway refuses a request it
/// cannot audit). Only changes made through rv are recorded; a crash between
/// the append and the write leaves an event that records intent only.
public enum ConfigChangeAudit {
    /// Which way a change moves the gate. `loosening` also covers a mixed
    /// change and one that cannot be classified: only a change known to
    /// tighten is `tightening`.
    public enum Direction: String, Sendable, Equatable {
        case tightening
        case loosening
    }

    /// How the change being persisted was authorized, e.g. `owner (rvd
    /// prompt)`. The caller that ran the owner check binds it around the
    /// store call; unbound reads as `none`.
    @TaskLocal public static var authorization: String?

    /// Longest wait for the audit log's locks before the change counts as
    /// unrecorded. Tests bind a shorter one.
    @TaskLocal public static var lockTimeout: Duration = .seconds(1)

    public static let unauthorized = "none"
    /// Prior value of a setting that had no stored entry.
    public static let unset = "unset"
    /// `reason` of the copy appended when the write threw after its event
    /// landed: some writes (a file, then a log line or a chmod) can fail
    /// part-way, so the copy does not claim nothing changed.
    public static let writeFailed = "write failed; may be partially applied"
    /// `reason` of a tightening change recorded after it was made.
    public static let recordedLate = "recorded after the change; the audit log was unavailable"

    /// One setting changed from `prior` to `new`.
    public static func setting(
        _ name: String, from prior: String, to new: String, direction: Direction,
        detail extra: [String: String] = [:], time: Date = Date()
    ) -> AuditEvent {
        var detail = extra
        detail["setting"] = name
        detail["prior"] = prior
        detail["new"] = new
        return event(.configChanged, subject: name, detail: detail, direction: direction, time: time)
    }

    /// A policy revision on `layer` (`machine` or `repo`). `change` is
    /// `save`, `rollback` or `reinitialize`. `workspace` is shown as given;
    /// callers pass it through `redacted`.
    public static func policy(
        layer: String, change: String, revision: Int, hash: String, ruleCount: Int,
        prior: (revision: Int, hash: String, ruleCount: Int)?, direction: Direction,
        workspace: String? = nil, time: Date = Date()
    ) -> AuditEvent {
        var detail = [
            "layer": layer, "change": change, "revision": String(revision), "hash": hash,
            "rule_count": String(ruleCount),
        ]
        if let prior {
            detail["prior_revision"] = String(prior.revision)
            detail["prior_hash"] = prior.hash
            detail["prior_rule_count"] = String(prior.ruleCount)
        }
        var event = event(.policyChanged, subject: layer, detail: detail, direction: direction, time: time)
        event.workspace = workspace
        return event
    }

    /// The event with `authorized_by` filled from the bound authorization
    /// and, when given, `direction`.
    public static func event(
        _ kind: AuditEventKind, subject: String, detail: [String: String], direction: Direction? = nil,
        time: Date = Date()
    ) -> AuditEvent {
        var detail = detail
        detail["authorized_by"] = detail["authorized_by"] ?? authorization ?? unauthorized
        if let direction { detail["direction"] = direction.rawValue }
        return AuditEvent(
            time: time, kind: kind, decision: .info, subject: subject,
            source: AuditLedger.Source.audit.rawValue, detail: detail)
    }

    /// `path` with the home directory above `configDirectory`
    /// (`<home>/.config/rv`) shown as `~`, as denial records show paths.
    public static func redacted(_ path: String, configDirectory: URL) -> String {
        let config = configDirectory.standardizedFileURL
        let parent = config.deletingLastPathComponent()
        guard config.lastPathComponent == "rv", parent.lastPathComponent == ".config" else { return path }
        return DenialPathRedaction.redact(path, home: HomePath(rawValue: parent.deletingLastPathComponent().path))
    }

    /// Write-ahead: appends `event`, then runs `write`.
    ///
    /// When the append fails (unwritable log, or its lock is not free within
    /// `lockTimeout`): an event whose `direction` is `tightening` still runs
    /// `write`, warns on stderr and is appended once more afterwards; any
    /// other event throws `ConfigChangeUnrecorded` and nothing is written.
    /// When `write` throws, a `failed` copy is appended (best effort) and the
    /// error is rethrown.
    public static func commit<T>(
        _ event: AuditEvent, configDirectory: URL, _ write: () throws -> T
    ) throws -> T {
        guard append(event, configDirectory) else {
            try refuseUnlessTightening(event)
            let result = try withFailedCopy(event, configDirectory, write)
            recordLate(event, configDirectory)
            return result
        }
        return try withFailedCopy(event, configDirectory, write)
    }

    /// `commit` for an async write.
    public static func commitAwaiting<T>(
        _ event: AuditEvent, configDirectory: URL, _ write: () async throws -> T
    ) async throws -> T {
        let recorded = append(event, configDirectory)
        if recorded == false { try refuseUnlessTightening(event) }
        let result: T
        do {
            result = try await write()
        } catch {
            append(failed(event), configDirectory)
            throw error
        }
        if recorded == false { recordLate(event, configDirectory) }
        return result
    }

    static func failed(_ event: AuditEvent) -> AuditEvent {
        var failed = event
        failed.time = Date()
        failed.decision = .failed
        failed.reason = writeFailed
        return failed
    }

    /// Comma-joined, sorted, for list-valued detail fields.
    public static func list<S: Sequence>(_ values: S) -> String where S.Element == String {
        values.sorted().joined(separator: ",")
    }

    @discardableResult
    private static func append(_ event: AuditEvent, _ configDirectory: URL) -> Bool {
        AuditLog.append(event, configDirectory: configDirectory, lockTimeout: lockTimeout)
    }

    private static func refuseUnlessTightening(_ event: AuditEvent) throws {
        guard event.detail["direction"] == Direction.tightening.rawValue else {
            throw ConfigChangeUnrecorded(subject: event.subject)
        }
    }

    private static func withFailedCopy<T>(
        _ event: AuditEvent, _ configDirectory: URL, _ write: () throws -> T
    ) throws -> T {
        do {
            return try write()
        } catch {
            append(failed(event), configDirectory)
            throw error
        }
    }

    /// A tightening change made while the log was unavailable: one more
    /// try to record it, and a warning either way. Events have no id, so
    /// the late record keeps the change's own time as `changed_at` and the
    /// warning names kind, subject and that time.
    private static func recordLate(_ event: AuditEvent, _ configDirectory: URL) {
        let changedAt = ISO8601DateFormatter().string(from: event.time)
        var late = event
        late.time = Date()
        late.reason = recordedLate
        late.detail["changed_at"] = changedAt
        let recorded = append(late, configDirectory)
        let line = "rv: warning: the audit log could not record \(event.kind.rawValue) \(event.subject) "
            + "at \(changedAt) when it was made; it was made anyway because it only tightens the gate"
            + (recorded ? " (recorded afterwards)" : " (still not recorded)") + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

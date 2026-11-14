import Foundation

/// The audit log could not record a gate change, so the change was not made.
public struct ConfigChangeUnrecorded: Error, Sendable, Equatable, CustomStringConvertible {
    public var subject: String

    public init(subject: String) {
        self.subject = subject
    }

    public var description: String {
        "the audit log could not record the \(subject) change, so it was not made"
    }
}

/// Audit events for changes to the gate itself: `policy.changed` (a new
/// machine or repo policy revision), `config.changed` (one setting such as
/// safety, a host mode, packs, the allowlist, secret definitions or an
/// egress review) and `policy.managed` (the organization bundle).
///
/// Events name what changed, the revision and content hash where there is
/// one, prior and new values of scalar settings, and how the change was
/// authorized. Never secret values, never policy bodies or command text.
///
/// Stores record write-ahead through `commit`: the event lands in the
/// hash-chained `audit.jsonl` before the change is written, so a change the
/// log cannot hold is not made (as the secret gateway refuses a request it
/// cannot audit).
public enum ConfigChangeAudit {
    /// How the change being persisted was authorized, e.g. `owner (rvd
    /// prompt)`. The caller that ran the owner check binds it around the
    /// store call; unbound reads as `none`.
    @TaskLocal public static var authorization: String?

    public static let unauthorized = "none"
    /// Prior value of a setting that had no stored entry.
    public static let unset = "unset"

    /// One setting changed from `prior` to `new`.
    public static func setting(
        _ name: String, from prior: String, to new: String, detail extra: [String: String] = [:], time: Date = Date()
    ) -> AuditEvent {
        var detail = extra
        detail["setting"] = name
        detail["prior"] = prior
        detail["new"] = new
        return event(.configChanged, subject: name, detail: detail, time: time)
    }

    /// A policy revision on `layer` (`machine` or `repo`). `change` is
    /// `save`, `rollback` or `reinitialize`.
    public static func policy(
        layer: String, change: String, revision: Int, hash: String, ruleCount: Int,
        prior: (revision: Int, hash: String, ruleCount: Int)?, workspace: String? = nil, time: Date = Date()
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
        var event = event(.policyChanged, subject: layer, detail: detail, time: time)
        event.workspace = workspace
        return event
    }

    /// The event with `authorized_by` filled from the bound authorization.
    public static func event(
        _ kind: AuditEventKind, subject: String, detail: [String: String], time: Date = Date()
    ) -> AuditEvent {
        var detail = detail
        detail["authorized_by"] = detail["authorized_by"] ?? authorization ?? unauthorized
        return AuditEvent(
            time: time, kind: kind, decision: .info, subject: subject,
            source: AuditLedger.Source.audit.rawValue, detail: detail)
    }

    /// Write-ahead: appends `event`, then runs `write`. When the append
    /// fails nothing is written and `ConfigChangeUnrecorded` is thrown. When
    /// `write` throws, a `failed` copy is appended (best effort) so the log
    /// does not claim a change that did not land, and the error is rethrown.
    public static func commit<T>(
        _ event: AuditEvent, configDirectory: URL, _ write: () throws -> T
    ) throws -> T {
        guard AuditLog.append(event, configDirectory: configDirectory) else {
            throw ConfigChangeUnrecorded(subject: event.subject)
        }
        do {
            return try write()
        } catch {
            AuditLog.append(failed(event), configDirectory: configDirectory)
            throw error
        }
    }

    /// `commit` for an async write.
    public static func commitAwaiting<T>(
        _ event: AuditEvent, configDirectory: URL, _ write: () async throws -> T
    ) async throws -> T {
        guard AuditLog.append(event, configDirectory: configDirectory) else {
            throw ConfigChangeUnrecorded(subject: event.subject)
        }
        do {
            return try await write()
        } catch {
            AuditLog.append(failed(event), configDirectory: configDirectory)
            throw error
        }
    }

    static func failed(_ event: AuditEvent) -> AuditEvent {
        var failed = event
        failed.time = Date()
        failed.decision = .failed
        failed.reason = "not saved"
        return failed
    }

    /// Comma-joined, sorted, for list-valued detail fields.
    public static func list<S: Sequence>(_ values: S) -> String where S.Element == String {
        values.sorted().joined(separator: ",")
    }
}

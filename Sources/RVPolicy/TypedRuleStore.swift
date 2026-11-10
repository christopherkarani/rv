#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore

public enum TypedRuleStoreError: Error, Sendable, Equatable {
    case lockFailed
    case invalidFile
    case unknownRevision
    /// F1: the machine revision log, its key, or its tip seal failed
    /// verification (forgery, reorder, truncation, or tamper). Fail closed.
    case logCorrupted
    /// F1: `policy.toml` exists but its revision log is gone. Saves,
    /// history, and rollback refuse until an explicit
    /// `reinitializeMachineLog()`; the log is never silently re-minted.
    case logMissing
    /// F1: no verified log record carries the requested revision.
    case revisionNotFound
}

/// One append-only policy revision. The embedded TOML is the full document at
/// this revision, so rollback re-parses it and saves it as a new head without
/// ever rewriting the log. Mirrors OpenShell's installation revision +
/// deterministic policy hash discipline.
///
/// Unified across both machine logs: the JSONL history carries the metadata
/// (`hash`, `ruleCount`, `recordedAt`) and the HMAC log carries the same
/// content sealed. Machine readers verify every field: TOML bytes and hash
/// plus the sealed record time must agree per generation, and the rule
/// count is recounted from the line's own TOML. Repo history has no sealed
/// log, so repo `recorded_at` is unverified display (documented residual);
/// repo `rule_count` is still recounted. The encoded form is metadata plus
/// TOML only, so log lines and CLI robot output never embed a redundant
/// parsed document.
public struct PolicyRevision: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var revision: Int
    /// `PolicyRevisionIdentity.hash` of the document: order-independent.
    public var hash: String
    public var ruleCount: Int
    public var recordedAt: Date
    public var toml: String
    public var document: PolicyDocument

    public init(
        schemaVersion: Int = currentSchemaVersion,
        revision: Int,
        hash: String,
        ruleCount: Int,
        recordedAt: Date,
        toml: String,
        document: PolicyDocument
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.hash = hash
        self.ruleCount = ruleCount
        self.recordedAt = recordedAt
        self.toml = toml
        self.document = document
    }

    /// Verified-record convenience: metadata is derived from the document,
    /// which is already parsed. Only the recorded time is new.
    public init(revision: Int, toml: String, document: PolicyDocument) {
        self.init(
            revision: revision,
            hash: PolicyRevisionIdentity.hash(document),
            ruleCount: document.rules.count,
            recordedAt: Date(),
            toml: toml,
            document: document
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case hash
        case ruleCount = "rule_count"
        case recordedAt = "recorded_at"
        case toml
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decode(Int.self, forKey: .schemaVersion)
        revision = try box.decode(Int.self, forKey: .revision)
        hash = try box.decode(String.self, forKey: .hash)
        ruleCount = try box.decode(Int.self, forKey: .ruleCount)
        recordedAt = try box.decode(Date.self, forKey: .recordedAt)
        toml = try box.decode(String.self, forKey: .toml)
        do {
            document = try PolicyDocumentTOML.parse(toml)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .toml,
                in: box,
                debugDescription: "unparseable revision TOML"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(schemaVersion, forKey: .schemaVersion)
        try box.encode(revision, forKey: .revision)
        try box.encode(hash, forKey: .hash)
        try box.encode(ruleCount, forKey: .ruleCount)
        try box.encode(recordedAt, forKey: .recordedAt)
        try box.encode(toml, forKey: .toml)
    }
}

/// Order-independent policy identity, mirroring OpenShell's
/// `canonical_rule_bytes` + `deterministic_policy_hash`. Rules are encoded to a
/// canonical string each, then sorted, so rule order never changes the hash.
/// `english` is provenance, not a matcher, and is excluded.
public enum PolicyRevisionIdentity {
    public static func hash(_ document: PolicyDocument) -> String {
        RVDigest.sha256Hex(canonicalBytes(document))
    }

    public static func canonicalBytes(_ document: PolicyDocument) -> [UInt8] {
        var bytes: [UInt8] = []
        func field(_ text: String) {
            bytes.append(contentsOf: text.utf8)
            bytes.append(0)
        }
        field("rv.policy.v1")
        field(String(document.schemaVersion))
        for rule in document.rules.map(canonicalRule).sorted() {
            field(rule)
        }
        field(document.safetyLevel?.rawValue ?? "-")
        for path in document.allowPaths.sorted() {
            field(path)
        }
        return bytes
    }

    public static func canonicalRule(_ rule: PolicyDocumentRule) -> String {
        "\(rule.id.rawValue)\u{0}\(rule.verdict.rawValue)\u{0}\(canonicalPredicate(rule.predicate))"
    }

    public static func canonicalPredicate(_ predicate: PolicyPredicate) -> String {
        switch predicate {
        case .gitPush(let force, let branch):
            let forceText: String
            switch force {
            case .any:
                forceText = "any"
            case .exactly(let value):
                forceText = value.rawValue
            }
            return "gitPush:\(forceText):\(branch ?? "-")"
        case .gitDiscardWorktree(let pathspec):
            return "gitDiscardWorktree:\(pathspec ?? "-")"
        case .gitReset(let mode):
            return "gitReset:\(mode?.rawValue ?? "-")"
        case .gitClean(let force, let directories):
            return "gitClean:\(flag(force)):\(flag(directories))"
        case .filesystemDelete(let recursive, let force):
            return "filesystemDelete:\(flag(recursive)):\(flag(force))"
        case .filesystemMove:
            return "filesystemMove"
        }
    }

    private static func flag(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "true" : "false"
    }
}

/// Test hooks for the rollbacks. Both closures run on the calling
/// thread while `.policy.lock` is held: `beforeLiveRead` before the
/// live file is loaded, `beforeWrite` after the gate and before the
/// write. Production passes nil.
struct RollbackInterlock {
    var beforeLiveRead: (() -> Void)?
    var beforeWrite: (() -> Void)?

    /// True when another open of `lockURL` cannot take `LOCK_EX`. Used to
    /// prove rollback still holds `.policy.lock` across the re-read and
    /// the write. A successful nonblocking acquire means it does not.
    static func policyLockIsHeld(at lockURL: URL) -> Bool {
        do {
            try ExclusiveFileLock.withLock(at: lockURL, nonBlocking: true) {}
            return false
        } catch {
            return true
        }
    }
}

typealias RepoRollbackInterlock = RollbackInterlock

/// Load/save/merge for compiled typed rules. I/O lives here; matching stays in Domain.
public struct TypedRuleStore: Sendable {
    public var baseDirectory: URL
    /// Wall clock for every minted timestamp. Production reads the system
    /// clock; tests inject a fixed one.
    private let now: @Sendable () -> Date

    public init(baseDirectory: URL) {
        self.init(baseDirectory: baseDirectory, now: Date.init)
    }

    init(baseDirectory: URL, now: @escaping @Sendable () -> Date) {
        self.baseDirectory = baseDirectory
        self.now = now
    }

    public var machineFileURL: URL {
        RVPolicyPaths.policyFile(inConfigDir: baseDirectory)
    }

    public var machineLegacyJSONURL: URL {
        RVPolicyPaths.typedRulesFile(inConfigDir: baseDirectory)
    }

    public func loadMachine() throws -> [TypedRule] {
        try loadDocument(toml: machineFileURL, json: machineLegacyJSONURL)
            .typedRules(origin: .machine)
    }

    public func loadMachineDocument() throws -> PolicyDocument {
        try loadDocument(toml: machineFileURL, json: machineLegacyJSONURL)
    }

    /// Replaces the rules and keeps the live schema version, safety level,
    /// and allow paths. The live document is read under the save locks, so
    /// a concurrent save of those fields is never clobbered by a stale read.
    public func saveMachine(_ rules: [TypedRule]) throws {
        try commitMachine {
            let existing = (try? loadMachineDocument()) ?? PolicyDocument()
            return Self.replacingRules(of: existing, with: rules)
        }
    }

    public func saveMachine(_ document: PolicyDocument) throws {
        try commitMachine { document }
    }

    /// Read-modify-write of machine `policy.toml` as one critical section:
    /// `transform` sees the live document under the same locks the save
    /// takes, so concurrent updates serialize instead of losing one. A
    /// throwing `transform` leaves `policy.toml` and the JSONL log
    /// untouched. Returns the saved document. `transform` must not call
    /// back into this store's saves, rollbacks, or history reads: the
    /// flock-based locks are not reentrant and would self-deadlock.
    @discardableResult
    func updateMachine(
        _ transform: (PolicyDocument) throws -> PolicyDocument
    ) throws -> PolicyDocument {
        try commitMachine { try transform(try loadMachineDocument()) }
    }

    /// The one machine save path. `next` runs with both locks held, right
    /// before the write.
    ///
    /// Dual-write, verified first: the HMAC log (tamper-evident history)
    /// and the JSONL revision log (CLI history) are both validated before
    /// the document moves, so a rejected save leaves the file and both
    /// logs untouched. Lock order is always log-lock then file-lock.
    /// One timestamp for both logs: the display `recorded_at` must equal
    /// the sealed `recorded_at_ms`, so two mints would brick the
    /// cross-check.
    @discardableResult
    private func commitMachine(
        _ next: () throws -> PolicyDocument
    ) throws -> PolicyDocument {
        try withFileLock(at: machineLogLockURL) {
            let chain = try reconcileInterruptedSave(verified: try loadVerifiedChain())
            let recordedAtMs = currentMs()
            let document = try withFileLock(at: machineLockURL) {
                let document = try next()
                try saveUnlocked(
                    document,
                    to: machineFileURL,
                    revisionsURL: machineRevisionsURL,
                    sealed: chain,
                    recordedAtMs: recordedAtMs
                )
                return document
            }
            try seal(
                toml: PolicyDocumentTOML.render(document),
                at: recordedAtMs,
                after: chain
            )
            return document
        }
    }

    private static func replacingRules(
        of existing: PolicyDocument,
        with rules: [TypedRule]
    ) -> PolicyDocument {
        PolicyDocument(
            schemaVersion: existing.schemaVersion,
            rules: rules.map { rule in
                PolicyDocumentRule(
                    id: rule.id,
                    verdict: rule.verdict,
                    predicate: rule.predicate
                )
            },
            safetyLevel: existing.safetyLevel,
            allowPaths: existing.allowPaths
        )
    }

    /// Verified machine history, oldest first. Empty only when neither
    /// `policy.toml` nor a log exists yet. Throws `logMissing` when the
    /// policy file exists without its log, and `logCorrupted` on any
    /// forgery, reorder, or truncation. Every read re-verifies the chain
    /// and cross-checks the display log against it.
    ///
    /// One public numbering: revisions are generations (the display
    /// sequence). Identical re-saves seal duplicate internal records
    /// without minting a generation, so internal sealed record numbers
    /// run ahead and are never exposed — a revision number from here,
    /// `listMachineRevisions()`, or `rv policy list` names the same
    /// generation in every rollback entry point.
    public func machineHistory() throws -> [PolicyRevision] {
        try listMachineRevisions()
    }

    /// Restore machine `policy.toml` to the exact bytes of a verified
    /// revision, then seal the restore as a new head record. Refuses
    /// unverifiable targets (`logCorrupted`) and unknown revisions
    /// (`revisionNotFound`) without touching `policy.toml`, so attacker
    /// TOML smuggled into a tampered log can never go live via rollback.
    /// Restoring a revision that drops a deny or ask, relaxes a surviving
    /// predicate's verdict, downgrades the safety level, or widens secret
    /// exemptions is refused (`blockedByFindings`) before anything is
    /// written. The gate compares the restored document with the live file
    /// and with the sealed head (see `refuseRelaxingRollback`). A deleted
    /// or already-weakened `policy.toml` cannot launder a revision weaker
    /// than the sealed head. An unparseable `policy.toml` is gated
    /// against the sealed head alone, so rollback stays the repair path
    /// for a corrupt hand-edit. Dropping an allow still succeeds.
    /// Returns the new head revision carrying the restored bytes.
    @discardableResult
    public func rollbackMachine(toRevision target: Int) throws -> PolicyRevision {
        try rollbackMachine(toRevision: target, interlock: nil)
    }

    @discardableResult
    func rollbackMachine(
        toRevision target: Int,
        interlock: RollbackInterlock?
    ) throws -> PolicyRevision {
        try withFileLock(at: machineLogLockURL) {
            let chain = try reconcileInterruptedSave(verified: try loadVerifiedChain())
            // Public revisions are generations, so `target` names the same
            // generation `machineHistory()` and `rv policy list` print.
            let (match, sealedHead) = try MachineRevisionLog.rollbackTarget(
                generation: target, in: chain
            )
            let data = Data(match.toml.utf8)
            let recordedAtMs = currentMs()
            var newHeadRevision = chain.generations.count
            try withFileLock(at: machineLockURL) {
                try prepareDirectory(machineFileURL.deletingLastPathComponent())
                // Cross-check under the held file lock: the display bytes
                // checked here are exactly the append base below, so a
                // forged display log refuses before anything is written.
                // Corruption outranks the risk gate: a truncated display
                // log must report logCorrupted, never a risk verdict
                // computed against history that failed verification.
                let display = try readRevisions(from: machineRevisionsURL)
                try MachineRevisionLog.checkDisplay(chain, matches: display)
                // Enforcement reads policy.toml and ignores the sealed log.
                // A deny edited into the live file is part of the posture
                // this restore would replace, even when the sealed
                // predicate set is unchanged. The sealed head is the other
                // baseline: deleting or weakening the file must not let an
                // older revision seal a posture the head already refused.
                interlock?.beforeLiveRead?()
                let live = try liveDocumentForRollbackGate { try loadMachineDocument() }
                try Self.refuseRelaxingRollback(
                    live: live,
                    historyHead: sealedHead.document,
                    incoming: match.document
                )
                let pending = try preparedRevisionLine(
                    document: match.document,
                    text: match.toml,
                    revisionsURL: machineRevisionsURL,
                    recordedAtMs: recordedAtMs
                )
                interlock?.beforeWrite?()
                try writeFileBytes(data, to: machineFileURL)
                if let pending {
                    try appendRevisionLine(pending, to: machineRevisionsURL)
                    newHeadRevision = display.count + 1
                }
            }
            let head = try seal(
                toml: match.toml, at: recordedAtMs, after: chain
            ).head
            return PolicyRevision(
                revision: newHeadRevision,
                hash: PolicyRevisionIdentity.hash(head.document),
                ruleCount: head.document.rules.count,
                recordedAt: MachineRevisionLog.date(ms: head.recordedAtMs),
                toml: head.toml,
                document: head.document
            )
        }
    }

    /// Explicit recovery from a deleted or damaged log: mints a fresh key,
    /// truncates the log, and seals the current on-disk machine document as
    /// r1. The on-disk document must parse; unparseable state fails closed
    /// with `invalidFile` instead of sealing garbage. This is the only path
    /// that re-mints a log after deletion — saves never do it silently.
    public func reinitializeMachineLog() throws {
        try withFileLock(at: machineLogLockURL) {
            let document = try loadMachineDocument()
            let toml = PolicyDocumentTOML.render(document)
            let recordedAtMs = currentMs()
            try seal(toml: toml, at: recordedAtMs, after: .fresh)
            // Reconcile the display log to the same single generation: the
            // old lines are unverifiable against the fresh key, so keeping
            // them would brick every cross-checked read. Operator recovery
            // explicitly restarts history from disk state; unverified past
            // lines are dropped, never laundered into the sealed chain.
            let display = PolicyRevision(
                revision: 1,
                hash: PolicyRevisionIdentity.hash(document),
                ruleCount: document.rules.count,
                recordedAt: MachineRevisionLog.date(ms: recordedAtMs),
                toml: toml,
                document: document
            )
            let line: Data
            do {
                line = try JSONEncoder().encode(display)
            } catch {
                throw TypedRuleStoreError.invalidFile
            }
            guard var text = String(data: line, encoding: .utf8) else {
                throw TypedRuleStoreError.invalidFile
            }
            text.append("\n")
            guard let lineData = text.data(using: .utf8) else {
                throw TypedRuleStoreError.invalidFile
            }
            try withFileLock(at: machineLockURL) {
                try writeFileBytes(lineData, to: machineRevisionsURL)
            }
        }
    }

    public static func repoFileURL(workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".rv", isDirectory: true)
            .appendingPathComponent("policy.toml", isDirectory: false)
    }

    public static func repoLegacyJSONURL(workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".rv", isDirectory: true)
            .appendingPathComponent("typed-rules.json", isDirectory: false)
    }

    public func loadRepo(workspace: URL) throws -> [TypedRule] {
        try loadRepoDocument(workspace: workspace).typedRules(origin: .repo)
    }

    public func loadRepoDocument(workspace: URL) throws -> PolicyDocument {
        try loadDocument(
            toml: Self.repoFileURL(workspace: workspace),
            json: Self.repoLegacyJSONURL(workspace: workspace)
        )
    }

    /// Replaces the rules and keeps the live schema version, safety level,
    /// and allow paths, read under the repo `.policy.lock`.
    public func saveRepo(_ rules: [TypedRule], workspace: URL) throws {
        try commitRepo(workspace: workspace) {
            let existing = (try? loadRepoDocument(workspace: workspace)) ?? PolicyDocument()
            return Self.replacingRules(of: existing, with: rules)
        }
    }

    public func saveRepo(_ document: PolicyDocument, workspace: URL) throws {
        try commitRepo(workspace: workspace) { document }
    }

    /// Read-modify-write of repo `.rv/policy.toml` under one `.policy.lock`
    /// hold. Same contract as `updateMachine`, including the no-reentry rule.
    @discardableResult
    func updateRepo(
        workspace: URL,
        _ transform: (PolicyDocument) throws -> PolicyDocument
    ) throws -> PolicyDocument {
        try commitRepo(workspace: workspace) {
            try transform(try loadRepoDocument(workspace: workspace))
        }
    }

    /// The one repo save path. `next` runs with `.policy.lock` held, right
    /// before the write.
    @discardableResult
    private func commitRepo(
        workspace: URL,
        _ next: () throws -> PolicyDocument
    ) throws -> PolicyDocument {
        let file = Self.repoFileURL(workspace: workspace)
        let lock = file.deletingLastPathComponent()
            .appendingPathComponent(".policy.lock", isDirectory: false)
        return try withFileLock(at: lock) {
            let document = try next()
            try saveUnlocked(
                document,
                to: file,
                revisionsURL: repoRevisionsURL(workspace: workspace)
            )
            return document
        }
    }

    public var machineRevisionsURL: URL {
        RVPolicyPaths.policyRevisionsFile(inConfigDir: baseDirectory)
    }

    public func repoRevisionsURL(workspace: URL) -> URL {
        RVPolicyPaths.repoRevisionsFile(inConfigDir: baseDirectory, workspace: workspace)
    }

    /// Revision log, oldest first. Missing log is empty and mints nothing.
    /// Revision log, oldest first. The .jsonl display log is cross-checked
    /// against the sealed HMAC log (BYPASS-1/2): a recomputed forgery
    /// throws `logCorrupted` and a deleted .jsonl against sealed history
    /// throws `logMissing`. Fresh state (no policy file, no logs) still
    /// lists empty without taking locks or minting anything.
    public func listMachineRevisions() throws -> [PolicyRevision] {
        guard FileManager.default.fileExists(atPath: machineRevisionsURL.path)
            || FileManager.default.fileExists(atPath: machineLogFileURL.path)
            || FileManager.default.fileExists(atPath: machineFileURL.path)
            || FileManager.default.fileExists(atPath: machineLogTipFileURL.path)
            || FileManager.default.fileExists(atPath: machineLogKeyFileURL.path)
        else {
            return []
        }
        return try lockedMachineSnapshot()
    }

    /// Revision log, oldest first. Missing log is empty and mints nothing.
    public func listRepoRevisions(workspace: URL) throws -> [PolicyRevision] {
        let revisionsURL = repoRevisionsURL(workspace: workspace)
        guard FileManager.default.fileExists(atPath: revisionsURL.path) else {
            return []
        }
        let file = Self.repoFileURL(workspace: workspace)
        let lock = file.deletingLastPathComponent()
            .appendingPathComponent(".policy.lock", isDirectory: false)
        return try withFileLock(at: lock) {
            try readRevisions(from: revisionsURL)
        }
    }

    /// Rollback re-submits an earlier revision's document as a new head
    /// revision. The log is append-only: earlier lines are never rewritten.
    /// Restoring a revision that is weaker than the live file or weaker
    /// than the sealed head is refused (`blockedByFindings`) before
    /// anything is written (see `refuseRelaxingRollback`). Dropping an
    /// allow still succeeds. Returns the new head.
    public func rollbackMachine(to revision: Int) throws -> PolicyRevision {
        // One implementation: the sealed, byte-exact, single-lock path.
        // Public revisions are generations in both spellings (see
        // `machineHistory()`), so this is a forwarder, not a second
        // rollback with its own numbering and lock discipline.
        do {
            return try rollbackMachine(toRevision: revision)
        } catch TypedRuleStoreError.revisionNotFound {
            throw TypedRuleStoreError.unknownRevision
        }
    }

    /// Rollback re-submits an earlier revision's document as a new head
    /// revision. The log is append-only: earlier lines are never rewritten.
    /// Restoring a revision that is weaker than the live file or weaker
    /// than the JSONL head is refused (`blockedByFindings`) before
    /// anything is written (see `refuseRelaxingRollback`). Dropping an
    /// allow still succeeds. Returns the new head.
    ///
    /// `.policy.lock` is held across the live re-read, both gates, and
    /// the write. `loadRepoDocument` does not take that lock.
    public func rollbackRepo(to revision: Int, workspace: URL) throws -> PolicyRevision {
        try rollbackRepo(to: revision, workspace: workspace, interlock: nil)
    }

    func rollbackRepo(
        to revision: Int,
        workspace: URL,
        interlock: RollbackInterlock?
    ) throws -> PolicyRevision {
        let file = Self.repoFileURL(workspace: workspace)
        let lock = file.deletingLastPathComponent()
            .appendingPathComponent(".policy.lock", isDirectory: false)
        let revisionsURL = repoRevisionsURL(workspace: workspace)
        try withFileLock(at: lock) {
            let entries = try readRevisions(from: revisionsURL)
            guard
                let target = entries.first(where: { $0.revision == revision }),
                let head = entries.last
            else {
                throw TypedRuleStoreError.unknownRevision
            }
            let targetDocument = try revisionDocument(target)
            // Re-read under the lock. A cooperative save that landed a
            // deny after an earlier unlocked read must still be visible
            // to the gate, and the write below stays in this same hold.
            interlock?.beforeLiveRead?()
            let live = try liveDocumentForRollbackGate {
                try loadRepoDocument(workspace: workspace)
            }
            try Self.refuseRelaxingRollback(
                live: live,
                historyHead: head.document,
                incoming: targetDocument
            )
            interlock?.beforeWrite?()
            try saveUnlocked(
                targetDocument,
                to: file,
                revisionsURL: revisionsURL
            )
        }
        let newHead = try listRepoRevisions(workspace: workspace).last
        guard let newHead else {
            throw TypedRuleStoreError.invalidFile
        }
        return newHead
    }

    /// Seam gate: a rollback restoring `incoming` refuses when that
    /// replacement is weaker than either baseline. The store owns only
    /// the dual-baseline orchestration; `PolicyDiffRisk` owns the
    /// replacement decision itself (`evaluateReplacement` with
    /// blocking exemption severity) at one deep seam.
    ///
    /// `live` is the file enforcement loads. `historyHead` is the sealed
    /// tail on the machine layer and the JSONL head on the repo layer.
    /// Dropping an allow is narrowing and does not refuse. Reviving an
    /// allow is advisory and does not block. Reviving a deny or ask
    /// tightens.
    /// `live == nil` is an unparseable live file: rollback is the
    /// repair path for exactly that state, so the history head alone
    /// gates the restore. The head baseline still refuses anything
    /// weaker than sealed, and a corrupt file holds no enforceable
    /// posture to compare against (loads fail closed on it too).
    private static func refuseRelaxingRollback(
        live: PolicyDocument?,
        historyHead: PolicyDocument,
        incoming: PolicyDocument
    ) throws {
        var baselines: [PolicyDocument] = []
        if let live {
            baselines.append(live)
        }
        baselines.append(historyHead)
        for baseline in baselines {
            let report = PolicyDiffRisk.evaluateReplacement(
                existing: baseline,
                incoming: incoming,
                secretExemptionSeverity: .blocking
            )
            if report.hasBlockingFindings {
                throw PolicyDiffRiskError.blockedByFindings(report)
            }
        }
    }

    /// Loads the live document for the rollback gate. Only
    /// `invalidFile` degrades to the head-only gate; every other
    /// failure still throws.
    private func liveDocumentForRollbackGate(
        _ load: () throws -> PolicyDocument
    ) throws -> PolicyDocument? {
        do {
            return try load()
        } catch TypedRuleStoreError.invalidFile {
            return nil
        }
    }

    public func loadEffective(builtin: [TypedRule], workspace: URL?) throws -> [TypedRule] {
        let machine = try loadMachine()
        let repo: [TypedRule]
        if let workspace {
            repo = try loadRepo(workspace: workspace)
        } else {
            repo = []
        }
        return Self.merge(builtin: builtin, machine: machine, repo: repo)
    }

    /// Restrict-only: later layers may tighten, never drop an earlier deny or ask.
    public static func merge(
        builtin: [TypedRule],
        machine: [TypedRule],
        repo: [TypedRule]
    ) -> [TypedRule] {
        var merged: [TypedRule] = []
        overlay(&merged, builtin, origin: .builtin)
        overlay(&merged, machine, origin: .machine)
        overlay(&merged, repo, origin: .repo)
        return merged
    }

    private static func overlay(
        _ merged: inout [TypedRule],
        _ incoming: [TypedRule],
        origin: TypedRuleOrigin
    ) {
        for rule in incoming {
            let stamped = TypedRule(
                id: rule.id,
                predicate: rule.predicate,
                verdict: rule.verdict,
                origin: origin
            )
            if let index = merged.firstIndex(where: { $0.predicate == stamped.predicate }) {
                if PolicyDiffRisk.restrictionRank(stamped.verdict) > PolicyDiffRisk.restrictionRank(merged[index].verdict) {
                    merged[index] = stamped
                }
            } else {
                merged.append(stamped)
            }
        }
    }

    private var machineLockURL: URL {
        RVPolicyPaths.policyLockFile(inConfigDir: baseDirectory)
    }

    private var machineLogLockURL: URL {
        RVPolicyPaths.policyRevisionLogLockFile(inConfigDir: baseDirectory)
    }

    private var machineLogFileURL: URL {
        RVPolicyPaths.policyRevisionLogFile(inConfigDir: baseDirectory)
    }

    private var machineLogKeyFileURL: URL {
        RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: baseDirectory)
    }

    private var machineLogTipFileURL: URL {
        RVPolicyPaths.policyRevisionLogTipFile(inConfigDir: baseDirectory)
    }

    /// F1 decision: loads are documented direct-edit — they read the current
    /// `policy.toml` bytes as-is and never consult the revision log. The
    /// machine file is owner-only in a 0700 directory, so only the owner can
    /// edit it; enforcement (`loadEffective`) must not depend on history
    /// availability. The HMAC log protects history and rollback only:
    /// `machineHistory` and `rollbackMachine` verify the full chain plus the
    /// sealed tip on every read, and rollback restores byte-exact verified
    /// content. Unparseable bytes still fail closed with `invalidFile`.
    private func loadDocument(
        toml: URL,
        json: URL
    ) throws -> PolicyDocument {
        if FileManager.default.fileExists(atPath: toml.path) {
            guard let text = try? String(contentsOf: toml, encoding: .utf8) else {
                throw TypedRuleStoreError.invalidFile
            }
            do {
                return try PolicyDocumentTOML.parse(text)
            } catch {
                throw TypedRuleStoreError.invalidFile
            }
        }
        return try loadLegacyJSON(from: json)
    }

    private func loadLegacyJSON(from url: URL) throws -> PolicyDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PolicyDocument()
        }
        guard let data = try? Data(contentsOf: url) else {
            throw TypedRuleStoreError.invalidFile
        }
        let document: TypedRulesDocument
        do {
            document = try JSONDecoder().decode(TypedRulesDocument.self, from: data)
        } catch {
            throw TypedRuleStoreError.invalidFile
        }
        guard document.schemaVersion == TypedRulesDocument.currentSchemaVersion else {
            throw TypedRuleStoreError.invalidFile
        }
        return PolicyDocument(
            rules: document.rules.map { rule in
                PolicyDocumentRule(
                    id: rule.id,
                    verdict: rule.verdict,
                    predicate: rule.predicate
                )
            }
        )
    }

    /// Caller holds the file lock for `url`. Repo rollback uses this so the
    /// live re-read, the gate, and the rename share one `.policy.lock`
    /// hold. `commitMachine` / `commitRepo` are the paths that acquire it.
    private func saveUnlocked(
        _ document: PolicyDocument,
        to url: URL,
        revisionsURL: URL,
        sealed: MachineRevisionLog.VerifiedChain? = nil,
        recordedAtMs: Int64? = nil
    ) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        let text = PolicyDocumentTOML.render(document)
        guard let data = text.data(using: .utf8) else {
            throw TypedRuleStoreError.invalidFile
        }
        // Validate the log and encode the pending line BEFORE mutating
        // the document: a corrupt log must fail closed without moving
        // the file, so the log can never fall behind a save it rejected.
        let pending = try preparedRevisionLine(
            document: document,
            text: text,
            revisionsURL: revisionsURL,
            recordedAtMs: recordedAtMs
        )
        if let sealed {
            // BYPASS-2: re-read under the held lock so the agreement
            // check sees exactly the bytes the append decision saw —
            // no check-to-use gap for a swapped display log.
            let display = try readRevisions(from: revisionsURL)
            try MachineRevisionLog.checkDisplay(sealed, matches: display)
        }
        try writeFileBytes(data, to: url)
        if let pending {
            try appendRevisionLine(pending, to: revisionsURL)
        }
    }

    private func revisionDocument(_ revision: PolicyRevision) throws -> PolicyDocument {
        do {
            return try PolicyDocumentTOML.parse(revision.toml)
        } catch {
            throw TypedRuleStoreError.invalidFile
        }
    }

    /// Locked dual-log snapshot for machine history reads (BYPASS-1/2):
    /// takes log-lock then file-lock (the documented order) and returns
    /// the display entries with the sealed records they must match.
    private func lockedMachineSnapshot() throws -> [PolicyRevision] {
        try withFileLock(at: machineLogLockURL) {
            try withFileLock(at: machineLockURL) {
                let entries = try readRevisions(from: machineRevisionsURL)
                let chain = try loadVerifiedChain()
                try MachineRevisionLog.checkDisplay(chain, matches: entries)
                return entries
            }
        }
    }

    private func readRevisions(from url: URL) throws -> [PolicyRevision] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw TypedRuleStoreError.invalidFile
        }
        var entries: [PolicyRevision] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let data = String(line).data(using: .utf8) else {
                throw TypedRuleStoreError.invalidFile
            }
            let entry: PolicyRevision
            do {
                entry = try JSONDecoder().decode(PolicyRevision.self, from: data)
            } catch {
                throw TypedRuleStoreError.invalidFile
            }
            guard entry.schemaVersion == PolicyRevision.currentSchemaVersion else {
                throw TypedRuleStoreError.invalidFile
            }
            // The log is append-only and gapless: entry N sits on line N.
            // A forged, reordered, or truncated-and-extended log fails closed
            // instead of minting rollback targets the saver never wrote.
            guard entry.revision == offset + 1 else {
                throw TypedRuleStoreError.invalidFile
            }
            let parsed: PolicyDocument
            do {
                parsed = try PolicyDocumentTOML.parse(entry.toml)
            } catch {
                throw TypedRuleStoreError.invalidFile
            }
            guard PolicyRevisionIdentity.hash(parsed) == entry.hash else {
                throw TypedRuleStoreError.invalidFile
            }
            // Display metadata is checked, not trusted: the rule count is
            // recounted from the line's own TOML (both layers), so a forged
            // `rule_count` fails closed like any other line forgery. The
            // timestamp check against the sealed record happens in
            // `MachineRevisionLog.checkDisplay` on the machine path.
            guard parsed.rules.count == entry.ruleCount else {
                throw TypedRuleStoreError.invalidFile
            }
            entries.append(entry)
        }
        return entries
    }

    /// Reads and validates the existing log and encodes the pending line, or
    /// nil when the head hash already matches: the head already is this
    /// document, so no new generation exists. Runs before the document file
    /// is mutated so a corrupt log fails closed without moving the file.
    private func preparedRevisionLine(
        document: PolicyDocument,
        text: String,
        revisionsURL: URL,
        recordedAtMs: Int64? = nil
    ) throws -> Data? {
        let entries = try readRevisions(from: revisionsURL)
        let hash = PolicyRevisionIdentity.hash(document)
        if entries.last?.hash == hash {
            return nil
        }
        // Machine callers pass the same instant they seal, so display and
        // sealed timestamps agree by construction. Repo saves have no
        // sealed counterpart and mint here; repo `recorded_at` stays
        // unverified display (same-uid forge on the repo layer is the
        // documented residual).
        let ms = recordedAtMs ?? currentMs()
        let entry = PolicyRevision(
            revision: (entries.last?.revision ?? 0) + 1,
            hash: hash,
            ruleCount: document.rules.count,
            recordedAt: MachineRevisionLog.date(ms: ms),
            toml: text,
            document: document
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(entry)
        } catch {
            throw TypedRuleStoreError.invalidFile
        }
        guard var line = String(data: data, encoding: .utf8) else {
            throw TypedRuleStoreError.invalidFile
        }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else {
            throw TypedRuleStoreError.invalidFile
        }
        return lineData
    }

    /// Appends one already-encoded revision line under the caller's lock.
    private func appendRevisionLine(
        _ lineData: Data,
        to url: URL
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else {
                throw TypedRuleStoreError.invalidFile
            }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
                try handle.close()
            } catch {
                throw TypedRuleStoreError.invalidFile
            }
        } else {
            do {
                try lineData.write(to: url, options: .atomic)
            } catch {
                throw TypedRuleStoreError.invalidFile
            }
        }
    }

    /// Atomic tmp-write + rename + owner-only chmod. Callers hold the lock
    /// for `url` and have prepared its parent directory.
    private func writeFileBytes(_ data: Data, to url: URL) throws {
        let temp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temp, options: .atomic)
        } catch {
            throw TypedRuleStoreError.invalidFile
        }
        try setOwnerOnlyFile(temp)
        let renamed: Int32 = url.withUnsafeFileSystemRepresentation { dest in
            temp.withUnsafeFileSystemRepresentation { src in
                guard let dest, let src else { return Int32(-1) }
                return rename(src, dest)
            }
        }
        if renamed != 0 {
            throw TypedRuleStoreError.invalidFile
        }
        try setOwnerOnlyFile(url)
    }

    private func withFileLock<T>(at lockURL: URL, _ body: () throws -> T) throws -> T {
        try prepareDirectory(lockURL.deletingLastPathComponent())
        do {
            return try ExclusiveFileLock.withLock(at: lockURL, body)
        } catch let error as ExclusiveFileLock.LockError {
            switch error {
            case .lockFailed:
                throw TypedRuleStoreError.lockFailed
            }
        }
    }

    private func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func setOwnerOnlyFile(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: - F1 revision log (I/O shell around MachineRevisionLog)

    /// Whole milliseconds on the injected clock: the one timestamp minted
    /// per save, shared by the display and sealed logs.
    private func currentMs() -> Int64 {
        MachineRevisionLog.ms(of: now())
    }

    /// Verified chain for a save or read. A present log is fully verified
    /// first so nothing builds on forged history. A missing log is only
    /// acceptable for a fresh config dir; `policy.toml` without its log is
    /// `logMissing`, never a silent re-mint.
    private func loadVerifiedChain() throws -> MachineRevisionLog.VerifiedChain {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: machineLogFileURL.path) else {
            return try MachineRevisionLog.classifyAbsent(
                policyFileExists: fileManager.fileExists(atPath: machineFileURL.path),
                remnantExists: fileManager.fileExists(atPath: machineLogTipFileURL.path)
                    || fileManager.fileExists(atPath: machineLogKeyFileURL.path)
            )
        }
        return try MachineRevisionLog.verify(
            logBytes: try? Data(contentsOf: machineLogFileURL),
            tipBytes: try? Data(contentsOf: machineLogTipFileURL),
            keyBytes: try? Data(contentsOf: machineLogKeyFileURL)
        )
    }

    /// Completes one interrupted dual-write when the pure decision says
    /// that is unambiguously what happened (see
    /// `MachineRevisionLog.reconcile`). Caller holds the log lock, which
    /// serializes all machine saves. A display log that cannot be read
    /// counts as empty, leaving the normal cross-check to judge.
    private func reconcileInterruptedSave(
        verified chain: MachineRevisionLog.VerifiedChain
    ) throws -> MachineRevisionLog.VerifiedChain {
        let entries = (try? readRevisions(from: machineRevisionsURL)) ?? []
        let liveText = try? String(contentsOf: machineFileURL, encoding: .utf8)
        switch MachineRevisionLog.reconcile(chain, display: entries, liveTOML: liveText) {
        case .unchanged:
            return chain
        case .sealTail(let toml, let recordedAtMs):
            return try seal(toml: toml, at: recordedAtMs, after: chain).chain
        }
    }

    /// Seals `toml` as the next head and persists the result: key (only
    /// when minted), then log, then tip. Full atomic rewrite on every seal:
    /// an append-one-line variant was rejected because a torn final line
    /// would fail the whole chain, while the rename keeps the on-disk log
    /// always complete.
    @discardableResult
    private func seal(
        toml: String,
        at recordedAtMs: Int64,
        after chain: MachineRevisionLog.VerifiedChain
    ) throws -> MachineRevisionLog.Appended {
        let appended = try MachineRevisionLog.appending(toml: toml, at: recordedAtMs, to: chain)
        if let mintedKey = appended.mintedKey {
            try writeKeyFile(mintedKey)
        }
        // Write failures are I/O, not tamper: `invalidFile` propagates so a
        // full disk never reads as forgery (whose documented recovery
        // destroys history). Verification failures stay `logCorrupted`.
        try prepareDirectory(baseDirectory)
        try writeFileBytes(appended.logBytes, to: machineLogFileURL)
        try writeFileBytes(appended.tipBytes, to: machineLogTipFileURL)
        return appended
    }

    private func writeKeyFile(_ raw: Data) throws {
        try prepareDirectory(baseDirectory)
        do {
            try raw.write(to: machineLogKeyFileURL, options: .atomic)
        } catch {
            throw TypedRuleStoreError.invalidFile
        }
        try setOwnerOnlyFile(machineLogKeyFileURL)
    }
}

private struct TypedRulesDocument: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var rules: [TypedRule]
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
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

/// Load/save/merge for compiled typed rules. I/O lives here; matching stays in Domain.
public struct TypedRuleStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
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

    public func saveMachine(_ rules: [TypedRule]) throws {
        let existing = (try? loadMachineDocument()) ?? PolicyDocument()
        try saveMachine(
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
        )
    }

    public func saveMachine(_ document: PolicyDocument) throws {
        // Dual-write, verified first: the HMAC log (tamper-evident history)
        // and the JSONL revision log (CLI history) are both validated before
        // the document moves, so a rejected save leaves the file and both
        // logs untouched. Lock order is always log-lock then file-lock.
        // One timestamp for both logs: the display `recorded_at` must equal
        // the sealed `recorded_at_ms`, so two mints would brick the
        // cross-check.
        try withFileLock(at: machineLogLockURL) {
            let records = try reconcileInterruptedSave(
                verified: try loadVerifiedLogForAppend()
            )
            let recordedAtMs = Self.nowMs()
            try save(
                document,
                to: machineFileURL,
                lockURL: machineLockURL,
                revisionsURL: machineRevisionsURL,
                sealed: records,
                recordedAtMs: recordedAtMs
            )
            try appendLogRecord(
                toml: PolicyDocumentTOML.render(document),
                after: records,
                recordedAtMs: recordedAtMs
            )
        }
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
    /// Restoring a revision that relaxes a surviving predicate's verdict,
    /// downgrades the safety level, or widens secret exemptions is
    /// refused (`blockedByFindings`) before anything is written;
    /// predicate-set change itself passes (see `refuseRelaxingRollback`). Returns the new head revision carrying the restored bytes.
    @discardableResult
    public func rollbackMachine(toRevision target: Int) throws -> PolicyRevision {
        try withFileLock(at: machineLogLockURL) {
            let records = try reconcileInterruptedSave(
                verified: try loadVerifiedLogForRead()
            )
            // Public revisions are generations: compress duplicate sealed
            // records (identical re-saves) exactly like the cross-check,
            // so `target` names the same generation `machineHistory()`
            // and `rv policy list` print.
            let generations = Self.compressedGenerations(records)
            guard
                target >= 1, target <= generations.count,
                let current = records.last
            else {
                throw TypedRuleStoreError.revisionNotFound
            }
            let match = generations[target - 1]
            guard let data = match.toml.data(using: .utf8) else {
                throw TypedRuleStoreError.logCorrupted
            }
            let recordedAtMs = Self.nowMs()
            var newHeadRevision = generations.count
            try withFileLock(at: machineLockURL) {
                try prepareDirectory(machineFileURL.deletingLastPathComponent())
                // Cross-check under the held file lock: the display bytes
                // checked here are exactly the append base below, so a
                // forged display log refuses before anything is written.
                // Corruption outranks the risk gate: a truncated display
                // log must report logCorrupted, never a risk verdict
                // computed against history that failed verification.
                let display = try readRevisions(from: machineRevisionsURL)
                try Self.checkJsonlMatchesSealed(entries: display, sealed: records)
                try Self.refuseRelaxingRollback(existing: current.document, incoming: match.document)
                let pending = try preparedRevisionLine(
                    document: match.document,
                    text: match.toml,
                    revisionsURL: machineRevisionsURL,
                    recordedAtMs: recordedAtMs
                )
                try writeFileBytes(data, to: machineFileURL)
                if let pending {
                    try appendRevisionLine(pending, to: machineRevisionsURL)
                    newHeadRevision = display.count + 1
                }
            }
            let head = try appendLogRecord(
                toml: match.toml, after: records, recordedAtMs: recordedAtMs
            )
            return PolicyRevision(
                revision: newHeadRevision,
                hash: PolicyRevisionIdentity.hash(head.document),
                ruleCount: head.document.rules.count,
                recordedAt: Self.date(ms: head.recordedAtMs),
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
            let key = SymmetricKey(size: .bits256)
            try writeKeyFile(key)
            let recordedAtMs = Self.nowMs()
            let mac = Self.recordMAC(
                revision: 1,
                prev: Self.logGenesis,
                recordedAtMs: recordedAtMs,
                toml: Data(toml.utf8),
                key: key
            )
            let record = RevisionLogRecord(
                revision: 1,
                prev: Self.logGenesis,
                tomlBase64: Data(toml.utf8).base64EncodedString(),
                recordedAtMs: recordedAtMs,
                mac: mac
            )
            try writeLogRecords([record])
            let tipMAC = Self.tipMAC(revision: 1, tip: mac, key: key)
            try writeLogTip(RevisionLogTip(revision: 1, tip: mac, mac: tipMAC))
            // Reconcile the display log to the same single generation: the
            // old lines are unverifiable against the fresh key, so keeping
            // them would brick every cross-checked read. Operator recovery
            // explicitly restarts history from disk state; unverified past
            // lines are dropped, never laundered into the sealed chain.
            let display = PolicyRevision(
                revision: 1,
                hash: PolicyRevisionIdentity.hash(document),
                ruleCount: document.rules.count,
                recordedAt: Self.date(ms: recordedAtMs),
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

    public func saveRepo(_ rules: [TypedRule], workspace: URL) throws {
        let existing = (try? loadRepoDocument(workspace: workspace)) ?? PolicyDocument()
        try saveRepo(
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
            ),
            workspace: workspace
        )
    }

    public func saveRepo(_ document: PolicyDocument, workspace: URL) throws {
        let file = Self.repoFileURL(workspace: workspace)
        let lock = file.deletingLastPathComponent()
            .appendingPathComponent(".policy.lock", isDirectory: false)
        try save(
            document,
            to: file,
            lockURL: lock,
            revisionsURL: repoRevisionsURL(workspace: workspace)
        )
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
        return try lockedMachineSnapshot().0
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
    /// Restoring a revision that relaxes a surviving predicate's verdict,
    /// downgrades the safety level, or widens secret exemptions is
    /// refused (`blockedByFindings`) before anything is written;
    /// predicate-set change itself passes (see `refuseRelaxingRollback`). Returns the new head.
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
    /// Restoring a revision that relaxes a surviving predicate's verdict,
    /// downgrades the safety level, or widens secret exemptions is
    /// refused (`blockedByFindings`) before anything is written;
    /// predicate-set change itself passes (see `refuseRelaxingRollback`). Returns the new head.
    public func rollbackRepo(to revision: Int, workspace: URL) throws -> PolicyRevision {
        let entries = try listRepoRevisions(workspace: workspace)
        guard
            let target = entries.first(where: { $0.revision == revision }),
            let head = entries.last
        else {
            throw TypedRuleStoreError.unknownRevision
        }
        let targetDocument = try revisionDocument(target)
        try Self.refuseRelaxingRollback(existing: head.document, incoming: targetDocument)
        try saveRepo(targetDocument, workspace: workspace)
        let newHead = try listRepoRevisions(workspace: workspace).last
        guard let newHead else {
            throw TypedRuleStoreError.invalidFile
        }
        return newHead
    }

    /// Seam gate: a rollback restoring `incoming` over the current `existing`
    /// head refuses when the restore would relax posture the head enforces
    /// on dimensions other than the predicate set itself:
    ///
    /// - an explicit verdict relaxation on a surviving predicate
    ///   (deny → ask/allow), via share semantics;
    /// - a safety-level downgrade (`strict` → anything else);
    /// - a widening of secret `allowPaths` beyond the head's exemptions.
    ///
    /// Predicate-set change is the rollback operation itself — restoring
    /// an earlier generation necessarily drops predicates the head added
    /// and revives ones it removed — so added/removed predicates do not
    /// refuse. (Full-replacement diffing would block nearly every real
    /// rollback; share semantics alone would silently pass the safety and
    /// exemption widenings above, which `evaluateShare` does not evaluate.)
    private static func refuseRelaxingRollback(
        existing: PolicyDocument,
        incoming: PolicyDocument
    ) throws {
        var findings = PolicyDiffRisk.evaluateShare(
            existing: existing,
            incoming: incoming
        ).findings
        if existing.safetyLevel == .strict, incoming.safetyLevel != .strict {
            findings.append(
                PolicyDiffRiskFinding(
                    kind: .safetyDowngrade,
                    severity: .blocking,
                    detail: "strict -> \(incoming.safetyLevel?.rawValue ?? "unset")"
                )
            )
        }
        for added in Set(incoming.allowPaths).subtracting(Set(existing.allowPaths)).sorted() {
            findings.append(
                PolicyDiffRiskFinding(
                    kind: .newSecretExemption,
                    severity: .blocking,
                    detail: added
                )
            )
        }
        let report = PolicyDiffRiskReport(findings: findings)
        if report.hasBlockingFindings {
            throw PolicyDiffRiskError.blockedByFindings(report)
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
                if restrictionRank(stamped.verdict) > restrictionRank(merged[index].verdict) {
                    merged[index] = stamped
                }
            } else {
                merged.append(stamped)
            }
        }
    }

    private static func restrictionRank(_ verdict: TypedRuleVerdict) -> Int {
        switch verdict {
        case .allow:
            0
        case .ask:
            1
        case .deny:
            2
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

    private func save(
        _ document: PolicyDocument,
        to url: URL,
        lockURL: URL,
        revisionsURL: URL,
        sealed: [VerifiedLogRecord]? = nil,
        recordedAtMs: Int64? = nil
    ) throws {
        try withFileLock(at: lockURL) {
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
                try Self.checkJsonlMatchesSealed(entries: display, sealed: sealed)
            }
            try writeFileBytes(data, to: url)
            if let pending {
                try appendRevisionLine(pending, to: revisionsURL)
            }
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
    private func lockedMachineSnapshot() throws -> ([PolicyRevision], [VerifiedLogRecord]) {
        try withFileLock(at: machineLogLockURL) {
            try withFileLock(at: machineLockURL) {
                let entries = try readRevisions(from: machineRevisionsURL)
                let sealed = try loadVerifiedLogForRead()
                try Self.checkJsonlMatchesSealed(entries: entries, sealed: sealed)
                return (entries, sealed)
            }
        }
    }

    /// Dual-log agreement (BYPASS-1/2): the display log must describe the
    /// same generation sequence as the sealed chain. Sealed records whose
    /// document hashes a repeat of the previous generation compress away
    /// first — identical (or same-hash) re-saves seal without appending a
    /// `.jsonl` line by design, so sealed numbering runs ahead and
    /// revisions are never compared across logs (each log is
    /// gapless-checked on its own read path). After compression the two
    /// sequences must agree in length and, per generation, in byte-exact
    /// TOML plus document hash plus sealed record time: a recomputed
    /// forgery, reorder, truncation, or timestamp edit fails
    /// `logCorrupted`, and an empty display list against non-empty sealed
    /// history (deleted `.jsonl`) fails `logMissing`.
    /// Generation sequence of a sealed chain: consecutive records whose
    /// documents hash identically (identical re-saves) compress to the
    /// first. Public revision N is generation N (1-based).
    private static func compressedGenerations(
        _ sealed: [VerifiedLogRecord]
    ) -> [VerifiedLogRecord] {
        var generations: [VerifiedLogRecord] = []
        generations.reserveCapacity(sealed.count)
        var previousHash: String? = nil
        for record in sealed {
            let hash = PolicyRevisionIdentity.hash(record.document)
            if hash != previousHash {
                generations.append(record)
                previousHash = hash
            }
        }
        return generations
    }

    private static func checkJsonlMatchesSealed(entries: [PolicyRevision], sealed: [VerifiedLogRecord]) throws {
        if entries.isEmpty {
            if sealed.isEmpty {
                return
            }
            throw TypedRuleStoreError.logMissing
        }
        let generations = compressedGenerations(sealed)
        guard generations.count == entries.count else {
            throw TypedRuleStoreError.logCorrupted
        }
        for (entry, record) in zip(entries, generations) {
            guard entry.toml == record.toml,
                entry.hash == PolicyRevisionIdentity.hash(record.document),
                Self.ms(of: entry.recordedAt) == record.recordedAtMs
            else {
                throw TypedRuleStoreError.logCorrupted
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
            // `checkJsonlMatchesSealed` on the machine path.
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
        let ms = recordedAtMs ?? Self.nowMs()
        let entry = PolicyRevision(
            revision: (entries.last?.revision ?? 0) + 1,
            hash: hash,
            ruleCount: document.rules.count,
            recordedAt: Self.date(ms: ms),
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

    // MARK: - F1 revision log

    private static let logGenesis = "genesis"
    private static let logKeyBytes = 32

    /// Verified records for an append. A present log is fully verified first
    /// so a save never builds on forged history. A missing log is only
    /// acceptable for a fresh config dir (no policy file, no remnants);
    /// `policy.toml` without its log is the deleted-log state and throws
    /// `logMissing` instead of silently re-minting r1.
    private func loadVerifiedLogForAppend() throws -> [VerifiedLogRecord] {
        guard FileManager.default.fileExists(atPath: machineLogFileURL.path) else {
            if FileManager.default.fileExists(atPath: machineFileURL.path) {
                throw TypedRuleStoreError.logMissing
            }
            if FileManager.default.fileExists(atPath: machineLogTipFileURL.path)
                || FileManager.default.fileExists(atPath: machineLogKeyFileURL.path)
            {
                throw TypedRuleStoreError.logCorrupted
            }
            return []
        }
        return try verifyLogChain()
    }

    /// Verified records for a read. Fresh state (no log, no policy) reads as
    /// empty history; every other missing-log shape fails closed.
    private func loadVerifiedLogForRead() throws -> [VerifiedLogRecord] {
        guard FileManager.default.fileExists(atPath: machineLogFileURL.path) else {
            if FileManager.default.fileExists(atPath: machineFileURL.path)
                || FileManager.default.fileExists(atPath: machineLogTipFileURL.path)
                || FileManager.default.fileExists(atPath: machineLogKeyFileURL.path)
            {
                if FileManager.default.fileExists(atPath: machineFileURL.path) {
                    throw TypedRuleStoreError.logMissing
                }
                throw TypedRuleStoreError.logCorrupted
            }
            return []
        }
        return try verifyLogChain()
    }

    /// Full-chain verification: contiguous 1-based revisions, `prev` linkage
    /// from `genesis`, a valid HMAC over revision + prev + recorded-at-ms +
    /// TOML bytes per record, parseable sealed TOML, and a MAC-sealed tip
    /// matching the last record (which is what makes truncation detectable).
    /// Any failure — including a missing key, a short key, an unreadable
    /// file, or a pre-timestamp record without `recorded_at_ms` — throws
    /// `logCorrupted`. Never mints or repairs.
    private func verifyLogChain() throws -> [VerifiedLogRecord] {
        guard let logData = try? Data(contentsOf: machineLogFileURL),
            let logText = String(data: logData, encoding: .utf8)
        else {
            throw TypedRuleStoreError.logCorrupted
        }
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.isEmpty == false else {
            throw TypedRuleStoreError.logCorrupted
        }
        guard let key = try? loadLogKey() else {
            throw TypedRuleStoreError.logCorrupted
        }
        let decoder = JSONDecoder()
        var verified: [VerifiedLogRecord] = []
        verified.reserveCapacity(lines.count)
        var expectedPrev = Self.logGenesis
        for (index, line) in lines.enumerated() {
            guard let lineData = String(line).data(using: .utf8),
                let record = try? decoder.decode(RevisionLogRecord.self, from: lineData),
                record.revision == index + 1,
                record.prev == expectedPrev,
                let tomlData = Data(base64Encoded: record.tomlBase64),
                let toml = String(data: tomlData, encoding: .utf8)
            else {
                throw TypedRuleStoreError.logCorrupted
            }
            let expected = Self.recordMAC(
                revision: record.revision,
                prev: record.prev,
                recordedAtMs: record.recordedAtMs,
                toml: tomlData,
                key: key
            )
            guard Self.constantTimeEqual(expected, record.mac) else {
                throw TypedRuleStoreError.logCorrupted
            }
            guard let document = try? PolicyDocumentTOML.parse(toml) else {
                throw TypedRuleStoreError.logCorrupted
            }
            verified.append(
                VerifiedLogRecord(
                    revision: record.revision,
                    prev: record.prev,
                    mac: record.mac,
                    recordedAtMs: record.recordedAtMs,
                    toml: toml,
                    document: document
                )
            )
            expectedPrev = record.mac
        }
        guard let tipData = try? Data(contentsOf: machineLogTipFileURL),
            let tip = try? decoder.decode(RevisionLogTip.self, from: tipData),
            let last = verified.last,
            tip.revision == last.revision,
            tip.tip == last.mac
        else {
            throw TypedRuleStoreError.logCorrupted
        }
        let expectedTipMAC = Self.tipMAC(revision: tip.revision, tip: tip.tip, key: key)
        guard Self.constantTimeEqual(expectedTipMAC, tip.mac) else {
            throw TypedRuleStoreError.logCorrupted
        }
        return verified
    }

    /// Completes one interrupted dual-write, if that is unambiguously what
    /// happened. `saveMachine` moves `policy.toml` + display log first and
    /// seals second (both under the log lock); a crash or write failure
    /// between the two left enforcement live on the new document while
    /// every later cross-checked operation threw `logCorrupted` until
    /// operator recovery destroyed history. When the display log is
    /// exactly the sealed generations plus one tail line whose TOML still
    /// equals the live `policy.toml` bytes, the missing seal is appended
    /// now and the completed chain returned. Any other shape is returned
    /// untouched for the normal cross-check to judge. Caller holds the
    /// log lock (which serializes all machine saves, so the display/doc
    /// snapshot cannot race another save).
    private func reconcileInterruptedSave(
        verified records: [VerifiedLogRecord]
    ) throws -> [VerifiedLogRecord] {
        let entries = (try? readRevisions(from: machineRevisionsURL)) ?? []
        let generations = Self.compressedGenerations(records)
        guard entries.count == generations.count + 1,
            let tail = entries.last
        else {
            return records
        }
        for (entry, record) in zip(entries, generations) {
            guard entry.toml == record.toml,
                entry.hash == PolicyRevisionIdentity.hash(record.document),
                Self.ms(of: entry.recordedAt) == record.recordedAtMs
            else {
                return records
            }
        }
        guard let liveText = try? String(contentsOf: machineFileURL, encoding: .utf8),
            liveText == tail.toml
        else {
            return records
        }
        let sealed = try appendLogRecord(
            toml: tail.toml,
            after: records,
            recordedAtMs: Self.ms(of: tail.recordedAt)
        )
        return records + [sealed]
    }

    /// Seals `toml` as the next head record after already-verified `records`
    /// and reseals the tip. Mints the key only for the first record of a
    /// fresh log; a key is never minted over an existing log.
    @discardableResult
    private func appendLogRecord(
        toml: String,
        after records: [VerifiedLogRecord],
        recordedAtMs: Int64
    ) throws -> VerifiedLogRecord {
        let key: SymmetricKey
        if records.isEmpty {
            key = SymmetricKey(size: .bits256)
            try writeKeyFile(key)
        } else {
            guard let existing = try? loadLogKey() else {
                throw TypedRuleStoreError.logCorrupted
            }
            key = existing
        }
        let tomlData = Data(toml.utf8)
        let revision = (records.last?.revision ?? 0) + 1
        let prev = records.last?.mac ?? Self.logGenesis
        let mac = Self.recordMAC(
            revision: revision, prev: prev, recordedAtMs: recordedAtMs, toml: tomlData, key: key
        )
        guard let document = try? PolicyDocumentTOML.parse(toml) else {
            throw TypedRuleStoreError.logCorrupted
        }
        let record = RevisionLogRecord(
            revision: revision,
            prev: prev,
            tomlBase64: tomlData.base64EncodedString(),
            recordedAtMs: recordedAtMs,
            mac: mac
        )
        // Append one line under the caller's log lock; the full rewrite
        // remains only for minting the first record. Re-encoding the whole
        // history per save made total work quadratic in saves.
        if records.isEmpty {
            try writeLogRecords([record])
        } else {
            try appendLogLine(record)
        }
        let tipMAC = Self.tipMAC(revision: revision, tip: mac, key: key)
        try writeLogTip(RevisionLogTip(revision: revision, tip: mac, mac: tipMAC))
        return VerifiedLogRecord(
            revision: revision,
            prev: prev,
            mac: mac,
            recordedAtMs: recordedAtMs,
            toml: toml,
            document: document
        )
    }

    /// Loads the 32-byte log key. Read paths only — throws when the key is
    /// missing or malformed and never mints one.
    private func loadLogKey() throws -> SymmetricKey {
        guard let data = try? Data(contentsOf: machineLogKeyFileURL),
            data.count == Self.logKeyBytes
        else {
            throw TypedRuleStoreError.logCorrupted
        }
        return SymmetricKey(data: data)
    }

    private func writeKeyFile(_ key: SymmetricKey) throws {
        try prepareDirectory(baseDirectory)
        let raw = key.withUnsafeBytes { Data($0) }
        guard raw.count == Self.logKeyBytes else {
            throw TypedRuleStoreError.logCorrupted
        }
        do {
            try raw.write(to: machineLogKeyFileURL, options: .atomic)
        } catch {
            throw TypedRuleStoreError.invalidFile
        }
        try setOwnerOnlyFile(machineLogKeyFileURL)
    }

    private func writeLogRecords(_ records: [RevisionLogRecord]) throws {
        try prepareDirectory(baseDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        lines.reserveCapacity(records.count)
        for record in records {
            guard let data = try? encoder.encode(record),
                let line = String(data: data, encoding: .utf8)
            else {
                throw TypedRuleStoreError.invalidFile
            }
            lines.append(line)
        }
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else {
            throw TypedRuleStoreError.invalidFile
        }
        // Write failures are I/O, not tamper: `invalidFile` propagates so a
        // full disk never reads as forgery (whose documented recovery
        // destroys history). Verification failures stay `logCorrupted`.
        try writeFileBytes(data, to: machineLogFileURL)
    }

    /// Appends one sealed record line under the caller's log lock.
    private func appendLogLine(_ record: RevisionLogRecord) throws {
        try prepareDirectory(baseDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(record),
            var line = String(data: encoded, encoding: .utf8)
        else {
            throw TypedRuleStoreError.invalidFile
        }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else {
            throw TypedRuleStoreError.invalidFile
        }
        guard let handle = try? FileHandle(forWritingTo: machineLogFileURL) else {
            throw TypedRuleStoreError.invalidFile
        }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: lineData)
            try handle.close()
        } catch {
            throw TypedRuleStoreError.invalidFile
        }
    }

    private func writeLogTip(_ tip: RevisionLogTip) throws {
        try prepareDirectory(baseDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(tip) else {
            throw TypedRuleStoreError.invalidFile
        }
        try writeFileBytes(data, to: machineLogTipFileURL)
    }

    private static func recordMAC(
        revision: Int,
        prev: String,
        recordedAtMs: Int64,
        toml: Data,
        key: SymmetricKey
    ) -> String {
        var message = Data("rv-policy-log/v1\n\(revision)\n\(prev)\n\(recordedAtMs)\n".utf8)
        message.append(toml)
        return hexEncode(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
    }

    private static func tipMAC(revision: Int, tip: String, key: SymmetricKey) -> String {
        let message = Data("rv-policy-log-tip/v1\n\(revision)\n\(tip)".utf8)
        return hexEncode(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
    }

    private static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Whole milliseconds since the epoch, the sealed timestamp unit.
    /// Integer milliseconds round-trip exactly through JSON; display
    /// `Date` values derive from them so the cross-check compares
    /// integers, never floats.
    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private static func ms(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(left, right) {
            diff |= a ^ b
        }
        return diff == 0
    }
}

private struct TypedRulesDocument: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var rules: [TypedRule]
}

/// F1: one JSONL line of `policy-revisions.log`. `mac` is HMAC-SHA256 keyed
/// by the per-config-dir key over `rv-policy-log/v1`, revision, prev, and
/// the raw TOML bytes — never an unkeyed hash, which anyone could forge.
private struct RevisionLogRecord: Codable, Sendable {
    var revision: Int
    var prev: String
    var tomlBase64: String
    /// Milliseconds since the epoch when the record sealed. Part of the
    /// MAC input: display `recorded_at` must match it, so forged
    /// timestamps refuse instead of landing in history output.
    var recordedAtMs: Int64
    var mac: String

    enum CodingKeys: String, CodingKey {
        case revision
        case prev
        case tomlBase64 = "toml_base64"
        case recordedAtMs = "recorded_at_ms"
        case mac
    }
}

/// F1: the sealed tip. The chain alone cannot detect a dropped tail (a
/// prefix still verifies), so the tip pins the head revision + head MAC.
private struct RevisionLogTip: Codable, Sendable {
    var revision: Int
    var tip: String
    var mac: String
}

/// A record that passed full-chain verification, with decoded TOML.
private struct VerifiedLogRecord: Sendable {
    var revision: Int
    var prev: String
    var mac: String
    var recordedAtMs: Int64
    var toml: String
    var document: PolicyDocument
}

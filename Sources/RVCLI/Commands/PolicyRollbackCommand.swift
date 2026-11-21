import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation

/// `rv policy rollback <revision> [--repo] [--save]`: re-submits an earlier
/// revision from the sealed log as a new head. Without `--save` it is a
/// read-only preview. `--save` takes the same owner check as
/// `rv policy apply --save`, then the store rollback, which re-runs the
/// relax gate under the policy lock. Shape borrowed from OpenShell's
/// `policy list` / `policy get --rev`:
/// https://docs.nvidia.com/openshell/latest/how-it-works/policies/manage-policies
struct PolicyRollbackCommand: AsyncParsableCommand, CommandUsage {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Preview or restore an earlier policy revision as a new head."
    )

    static let usage = [
        HelpRow(name: "rv policy rollback <revision> [--repo] [--save [--wait [--wait-timeout <seconds>]]] [--json]"),
    ]

    @Argument(help: "Revision to restore, as rv policy list prints it (3 or r3).")
    var revision: PolicyRevisionNumber

    @Flag(name: .customLong("save"), help: "Restore the revision (asks for owner approval).")
    var save = false

    @Flag(name: .customLong("repo"), help: "Roll back the repo layer.")
    var repo = false

    @OptionGroup
    var format: FormatFlags

    @OptionGroup
    var waitFlags: PolicyWaitFlags

    func validate() throws {
        try waitFlags.check(save: save)
    }

    func run() async throws {
        let ctx = CommandContext.current(command: "policy rollback", format: format)
        let home = try ctx.requireHome()
        let workspace = URL(fileURLWithPath: CLIProcess.workspacePath(), isDirectory: true)
        try await PolicyRollbackRun.execute(
            session: PolicyWorkspace(home: home, workspace: workspace),
            layer: repo ? .repo : .machine,
            revision: revision.value,
            save: save,
            robot: ctx.explicitRobot,
            confirm: { summary in
                try await OwnerConfirmation.require(summary)
            },
            awaitLoad: { hash in
                try await PolicyLoadWait.confirm(
                    command: "policy rollback", layer: repo ? .repo : .machine, hash: hash,
                    flags: waitFlags, robot: ctx.explicitRobot)
            }
        )
    }
}

/// A revision as `rv policy list` prints it: `3` or `r3`, at least 1.
struct PolicyRevisionNumber: ExpressibleByArgument, Equatable, Sendable {
    let value: Int

    init?(argument: String) {
        let digits = argument.hasPrefix("r") ? String(argument.dropFirst()) : argument
        guard digits.isEmpty == false, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
            let value = Int(digits), value >= 1
        else {
            return nil
        }
        self.value = value
    }
}

enum PolicyRollbackRun {
    enum Outcome: Equatable {
        case preview
        case blocked
        case unchanged
        case restored(PolicyRevision)

        var name: String {
            switch self {
            case .preview: "preview"
            case .blocked: "blocked"
            case .unchanged: "unchanged"
            case .restored: "restored"
            }
        }
    }

    /// The whole command after argument parsing. `confirm` is the owner
    /// check (`OwnerConfirmation.require` in the CLI) and returns the
    /// authorization the audit event records; tests inject it to
    /// model what happens between approval and write. The write is bound
    /// to the previewed head, so a layer that moved after the preview
    /// refuses `headChanged`, and the store re-runs the relax gate under
    /// the lock, so a live-file edit with the head unchanged refuses too.
    static func execute(
        session: PolicyWorkspace,
        layer: PolicyDocumentLayer,
        revision: Int,
        save: Bool,
        robot: Bool,
        confirm: (String) async throws -> String,
        awaitLoad: (_ hash: String) async throws -> Void = { _ in }
    ) async throws {
        let repo = layer == .repo
        let preview: PolicyWorkspace.RollbackPreview
        do {
            preview = try session.previewRollback(layer: layer, to: revision)
        } catch {
            try CommandContext.fail(failure(error, revision: revision, repo: repo))
        }
        guard save else {
            CommandContext.writeStdout(try render(preview, outcome: .preview, robot: robot))
            return
        }
        if preview.risk.hasBlockingFindings {
            try refuseBlocked(preview, robot: robot)
        }
        if preview.isNoOp {
            // Nothing to restore: no owner prompt, nothing written.
            CommandContext.writeStdout(try render(preview, outcome: .unchanged, robot: robot))
            try await awaitLoad(preview.target.hash)
            return
        }
        if let refusal = preview.ceilingRefusal {
            // Like `policy apply --save`: outside the owner's ceiling, no prompt.
            try refuseCeiling(refusal, preview, robot: robot)
        }
        if robot == false {
            // The owner sees what they approve before the prompt.
            CommandContext.writeStdout(pretty(preview, outcome: .preview, footer: false))
        }
        let authorization = try await confirm("roll the \(layerName(layer)) policy back to r\(revision)")
        let restored: PolicyRevision
        do {
            restored = try ConfigChangeAudit.$authorization.withValue(authorization) {
                try session.rollback(
                    layer: layer, to: revision,
                    expected: PolicyRollbackBinding(target: preview.target, head: preview.head))
            }
        } catch let unrecorded as ConfigChangeUnrecorded {
            try ConfigChangeRefusal.fail(command: "policy rollback", unrecorded)
        } catch PolicyDiffRiskError.blockedByFindings(let report) {
            var refused = preview
            refused.risk = report
            try refuseBlocked(refused, robot: robot)
        } catch let error as PolicyCeilingError {
            // The ceiling changed after the preview; re-checked under the lock.
            var refused = preview
            refused.ceilingRefusal = error
            try refuseCeiling(error, refused, robot: robot)
        } catch {
            try CommandContext.fail(failure(error, revision: revision, repo: repo))
        }
        if robot {
            CommandContext.writeStdout(try render(preview, outcome: .restored(restored), robot: true))
        } else {
            CommandContext.writeStdout("restored r\(revision) as r\(restored.revision)\n")
        }
        try await awaitLoad(restored.hash)
    }

    private static func refuseBlocked(_ preview: PolicyWorkspace.RollbackPreview, robot: Bool) throws -> Never {
        CommandContext.writeStdout(try render(preview, outcome: .blocked, robot: robot))
        try CommandContext.fail("rv policy rollback: blocked by policy risk findings\n", exitCode: 2)
    }

    private static func refuseCeiling(
        _ refusal: PolicyCeilingError, _ preview: PolicyWorkspace.RollbackPreview, robot: Bool
    ) throws -> Never {
        CommandContext.writeStdout(try render(preview, outcome: .blocked, robot: robot))
        try CommandContext.fail("rv policy rollback: refused: \(refusal.refusal); nothing was changed\n")
    }

    struct EffectiveDiff: Equatable, Sendable, Codable {
        struct Change: Equatable, Sendable, Codable {
            var from: TypedRule
            var to: TypedRule
        }

        var added: [TypedRule]
        var removed: [TypedRule]
        var changed: [Change]

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    }

    static func layerName(_ layer: PolicyDocumentLayer) -> String {
        layer == .machine ? "machine" : "repo"
    }

    /// Effective rules carry one row per predicate (the merge keeps the
    /// strictest), so the predicate is the diff key.
    static func diff(current: [TypedRule], restored: [TypedRule]) -> EffectiveDiff {
        var added: [TypedRule] = []
        var changed: [EffectiveDiff.Change] = []
        for rule in restored {
            if let before = current.first(where: { $0.predicate == rule.predicate }) {
                if before != rule {
                    changed.append(EffectiveDiff.Change(from: before, to: rule))
                }
            } else {
                added.append(rule)
            }
        }
        let removed = current.filter { rule in
            restored.contains { $0.predicate == rule.predicate } == false
        }
        return EffectiveDiff(added: added, removed: removed, changed: changed)
    }

    static func effectiveDiff(_ preview: PolicyWorkspace.RollbackPreview) -> EffectiveDiff? {
        guard let current = preview.currentEffective, let restored = preview.restoredEffective else {
            return nil
        }
        return diff(current: current, restored: restored)
    }

    static func render(
        _ preview: PolicyWorkspace.RollbackPreview,
        outcome: Outcome,
        robot: Bool
    ) throws -> String {
        guard robot else {
            return pretty(preview, outcome: outcome, footer: true)
        }
        do {
            return try RobotJSON.encode(robotDocument(preview, outcome: outcome), options: .compactISO8601) + "\n"
        } catch {
            try CommandContext.fail("rv policy rollback: encode failed\n")
        }
    }

    static func pretty(
        _ preview: PolicyWorkspace.RollbackPreview,
        outcome: Outcome,
        footer: Bool
    ) -> String {
        var lines = [
            "rollback \(layerName(preview.layer)) r\(preview.target.revision)",
            "  restore: \(revisionLine(preview.target))",
            "  head:    \(revisionLine(preview.head))",
        ]
        if preview.liveParses == false {
            lines.append("  live policy file does not parse; the gate judges the head alone")
        }
        lines.append("effective (current -> restored)")
        if let diff = effectiveDiff(preview) {
            if diff.isEmpty {
                lines.append("  (no change)")
            }
            lines += diff.removed.map { "  - \(ruleText($0))" }
            lines += diff.added.map { "  + \(ruleText($0))" }
            lines += diff.changed.map { "  ~ \(ruleText($0.from)) -> \($0.to.verdict.rawValue) (\($0.to.origin.rawValue))" }
        } else {
            lines.append("  (unavailable: a policy file does not parse)")
        }
        lines += preview.risk.previewLines
        if let refusal = preview.ceilingRefusal {
            lines.append("ceiling: \(refusal.refusal)")
        }
        if footer {
            switch outcome {
            case .preview:
                // Same order as `execute`: risk, no-op, ceiling.
                if preview.risk.hasBlockingFindings {
                    lines.append("preview only: --save would be refused")
                } else if preview.isNoOp {
                    lines.append("preview only: r\(preview.target.revision) is already the current policy")
                } else if preview.ceilingRefusal != nil {
                    lines.append("preview only: --save would be refused")
                } else {
                    lines.append("preview only: nothing was written; add --save to restore")
                }
            case .blocked:
                lines.append("refused: nothing was written")
            case .unchanged:
                lines.append("r\(preview.target.revision) is already the current policy; nothing was written")
            case .restored(let head):
                lines.append("restored r\(preview.target.revision) as r\(head.revision)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Refusal line for a store error. `policy show` is a read, so its
    /// lines do not claim "nothing was changed".
    static func failure(
        _ error: Error, revision: Int, repo: Bool, command: String = "policy rollback"
    ) -> String {
        let prefix = "rv \(command): "
        let writes = command == "policy rollback"
        let unchanged = writes ? "; nothing was changed" : ""
        switch error {
        case TypedRuleStoreError.unknownRevision, TypedRuleStoreError.revisionNotFound:
            return prefix + "unknown revision r\(revision) (see rv policy list\(repo ? " --repo" : ""))\n"
        case TypedRuleStoreError.headChanged:
            return prefix + "policy changed since preview; nothing was rolled back. Re-run to review the new head.\n"
        case TypedRuleStoreError.logCorrupted:
            // Machine only (the repo log has no seal). A crash between the
            // policy.toml write and the seal also lands here; the next
            // ordinary save reconciles that interrupted write.
            return prefix + "the policy revision log failed verification\(unchanged). "
                + "If a policy save was interrupted, the next policy save (for example rv policy apply --save) "
                + "completes it; otherwise the log was altered.\n"
        case TypedRuleStoreError.logMissing:
            return prefix + "the policy revision log is missing\(unchanged)\n"
        case TypedRuleStoreError.lockFailed:
            return prefix + "could not lock the policy files\(unchanged)\n"
        case TypedRuleStoreError.invalidFile:
            return prefix + "invalid policy file\n"
        case TypedRuleStoreError.documentTooLarge:
            return prefix + "refused: \(PolicySaveRefusal.tooLarge)\n"
        default:
            return prefix + "failed\(unchanged)\n"
        }
    }

    private static func revisionLine(_ entry: PolicyRevision) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "r\(entry.revision) \(entry.hash.prefix(12)) rules=\(entry.ruleCount) recorded \(formatter.string(from: entry.recordedAt))"
    }

    private static func ruleText(_ rule: TypedRule) -> String {
        "\(DisplayedText.field(rule.id.rawValue)) \(rule.verdict.rawValue) \(predicateText(rule.predicate)) (\(rule.origin.rawValue))"
    }

    static func robotDocument(
        _ preview: PolicyWorkspace.RollbackPreview,
        outcome: Outcome
    ) -> PolicyRollbackRobotDocument {
        var restoredAs: PolicyRollbackRobotDocument.Revision?
        if case .restored(let head) = outcome {
            restoredAs = .init(head)
        }
        return PolicyRollbackRobotDocument(
            layer: layerName(preview.layer),
            outcome: outcome.name,
            target: .init(preview.target),
            head: .init(preview.head),
            restoredAs: restoredAs,
            liveParses: preview.liveParses,
            effective: effectiveDiff(preview),
            risk: .init(preview.risk),
            ceilingRefusal: preview.ceilingRefusal?.refusal
        )
    }
}

/// `rv policy rollback --json`. `restored_as` appears only when the
/// rollback was written; `effective` is absent when a policy file does
/// not parse. `ceiling_refusal` appears only when the restored revision is
/// outside the owner's policy ceiling (or `ceiling.toml` is invalid), so
/// `--save` would refuse. Revisions carry metadata only, never the TOML.
struct PolicyRollbackRobotDocument: Equatable, Sendable, Codable {
    struct Revision: Equatable, Sendable, Codable {
        var revision: Int
        var hash: String
        var ruleCount: Int
        var recordedAt: Date

        init(_ entry: PolicyRevision) {
            revision = entry.revision
            hash = entry.hash
            ruleCount = entry.ruleCount
            recordedAt = entry.recordedAt
        }

        enum CodingKeys: String, CodingKey {
            case revision
            case hash
            case ruleCount = "rule_count"
            case recordedAt = "recorded_at"
        }
    }

    struct Risk: Equatable, Sendable, Codable {
        struct Finding: Equatable, Sendable, Codable {
            var kind: String
            var severity: String
            var detail: String
        }

        var blocking: Int
        var advisory: Int
        var findings: [Finding]

        init(_ report: PolicyDiffRiskReport) {
            blocking = report.blockingFindings.count
            advisory = report.advisoryFindings.count
            findings = report.findings.map {
                Finding(kind: $0.kind.rawValue, severity: $0.severity.rawValue, detail: $0.detail)
            }
        }
    }

    static let schemaName = "rv.policy.rollback.v1"

    var schema = Self.schemaName
    var layer: String
    var outcome: String
    var target: Revision
    var head: Revision
    var restoredAs: Revision?
    var liveParses: Bool
    var effective: PolicyRollbackRun.EffectiveDiff?
    var risk: Risk
    var ceilingRefusal: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case layer
        case outcome
        case target
        case head
        case restoredAs = "restored_as"
        case liveParses = "live_parses"
        case effective
        case risk
        case ceilingRefusal = "ceiling_refusal"
    }
}

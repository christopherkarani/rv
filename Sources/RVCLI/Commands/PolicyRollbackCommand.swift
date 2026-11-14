import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

/// `rv policy rollback <revision> [--repo] [--save]`: re-submits an earlier
/// revision from the sealed log as a new head. Without `--save` it is a
/// read-only preview. `--save` takes the same owner check as
/// `rv policy apply --save`, then the store rollback, which re-runs the
/// relax gate under the policy lock. Shape borrowed from OpenShell's
/// `policy list` / `policy get --rev`:
/// https://docs.nvidia.com/openshell/latest/how-it-works/policies/manage-policies
struct PolicyRollbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Preview or restore an earlier policy revision as a new head."
    )

    @Argument(help: "Revision to restore, as rv policy list prints it (3 or r3).")
    var revision: PolicyRevisionNumber

    @Flag(name: .customLong("save"), help: "Restore the revision (asks for owner approval).")
    var save = false

    @Flag(name: .customLong("repo"), help: "Roll back the repo layer.")
    var repo = false

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "policy rollback", format: format)
        let home = try ctx.requireHome()
        let workspace = URL(fileURLWithPath: CLIProcess.workspacePath(), isDirectory: true)
        let session = PolicyWorkspace(home: home, workspace: workspace)
        let layer: PolicyDocumentLayer = repo ? .repo : .machine
        let number = revision.value
        let preview: PolicyWorkspace.RollbackPreview
        do {
            preview = try session.previewRollback(layer: layer, to: number)
        } catch {
            try ctx.fail(PolicyRollbackRun.failure(error, revision: number, repo: repo))
        }
        guard save else {
            ctx.writeStdout(try PolicyRollbackRun.render(preview, outcome: .preview, robot: ctx.explicitRobot))
            return
        }
        if preview.risk.hasBlockingFindings {
            ctx.writeStdout(try PolicyRollbackRun.render(preview, outcome: .blocked, robot: ctx.explicitRobot))
            try ctx.fail("rv policy rollback: blocked by policy risk findings\n", exitCode: 2)
        }
        if ctx.explicitRobot == false {
            // The owner sees what they approve before the prompt.
            ctx.writeStdout(PolicyRollbackRun.pretty(preview, outcome: .preview, footer: false))
        }
        try await OwnerConfirmation.require(
            "roll the \(PolicyRollbackRun.layerName(layer)) policy back to r\(number)")
        let restored: PolicyRevision
        do {
            restored = try session.rollback(layer: layer, to: number)
        } catch PolicyDiffRiskError.blockedByFindings(let report) {
            // The store gate re-judged under the lock: the layer changed
            // since the preview. Nothing was written.
            var refused = preview
            refused.risk = report
            ctx.writeStdout(try PolicyRollbackRun.render(refused, outcome: .blocked, robot: ctx.explicitRobot))
            try ctx.fail("rv policy rollback: blocked by policy risk findings\n", exitCode: 2)
        } catch {
            try ctx.fail(PolicyRollbackRun.failure(error, revision: number, repo: repo))
        }
        if ctx.explicitRobot {
            ctx.writeStdout(try PolicyRollbackRun.render(preview, outcome: .restored(restored), robot: true))
        } else {
            ctx.writeStdout("restored r\(number) as r\(restored.revision)\n")
        }
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
        case restored(PolicyRevision)

        var name: String {
            switch self {
            case .preview: "preview"
            case .blocked: "blocked"
            case .restored: "restored"
            }
        }
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
        if footer {
            switch outcome {
            case .preview:
                lines.append(
                    preview.risk.hasBlockingFindings
                        ? "preview only: --save would be refused"
                        : "preview only: nothing was written; add --save to restore")
            case .blocked:
                lines.append("refused: nothing was written")
            case .restored(let head):
                lines.append("restored r\(preview.target.revision) as r\(head.revision)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func failure(
        _ error: Error, revision: Int, repo: Bool, command: String = "policy rollback"
    ) -> String {
        let prefix = "rv \(command): "
        switch error {
        case TypedRuleStoreError.unknownRevision, TypedRuleStoreError.revisionNotFound:
            return prefix + "unknown revision r\(revision) (see rv policy list\(repo ? " --repo" : ""))\n"
        case TypedRuleStoreError.logCorrupted:
            return prefix + "the policy revision log failed verification; nothing was changed\n"
        case TypedRuleStoreError.logMissing:
            return prefix + "the policy revision log is missing; nothing was changed\n"
        case TypedRuleStoreError.lockFailed:
            return prefix + "could not lock the policy files; nothing was changed\n"
        case TypedRuleStoreError.invalidFile:
            return prefix + "invalid policy file\n"
        default:
            return prefix + "failed; nothing was changed\n"
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
            risk: .init(preview.risk)
        )
    }
}

/// `rv policy rollback --json`. `restored_as` appears only when the
/// rollback was written; `effective` is absent when a policy file does
/// not parse. Revisions carry metadata only, never the TOML.
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
    }
}

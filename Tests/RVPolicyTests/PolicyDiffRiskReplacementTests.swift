import Testing
import RVDomain
@testable import RVPolicy

/// Table tests at the replacement-decision seam: `PolicyDiffRisk`
/// `evaluateReplacement` owns strictest dedup, share, removed, safety,
/// and exemption findings for replacing one document with another.
/// Rollback passes `.blocking` for new secret exemptions; the CLI
/// `evaluate` path passes `.advisory`. One explicit severity parameter
/// at the interface keeps that split in the open, so callers and tests
/// cross one seam. Rollback store tests (`RollbackRiskGateTests`) keep
/// proving the same gate outcomes through the store.
struct PolicyDiffRiskReplacementTests {
    private let predicate = PolicyPredicate.gitPush(
        force: .exactly(.force), branch: "main"
    )
    private let otherPredicate = PolicyPredicate.gitDiscardWorktree(pathspec: nil)

    private func rule(
        _ pattern: String,
        verdict: TypedRuleVerdict,
        on predicate: PolicyPredicate? = nil
    ) -> PolicyDocumentRule {
        PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: pattern),
            verdict: verdict,
            predicate: predicate ?? self.predicate
        )
    }

    private func replacement(
        existing: PolicyDocument,
        incoming: PolicyDocument,
        severity: PolicyDiffRiskFinding.Severity = .blocking
    ) -> PolicyDiffRiskReport {
        PolicyDiffRisk.evaluateReplacement(
            existing: existing,
            incoming: incoming,
            secretExemptionSeverity: severity
        )
    }

    @Test func duplicateAllowThenDenyNamesTheStrictestVerdict() {
        // Enforcement ranks the strictest duplicate row, so the first
        // (allow) row must not hide the deny a replacement would lose.
        let existing = PolicyDocument(rules: [
            rule("first", verdict: .allow),
            rule("second", verdict: .deny),
        ])
        let incoming = PolicyDocument(rules: [rule("gated", verdict: .allow)])

        let report = replacement(existing: existing, incoming: incoming)

        #expect(report.hasBlockingFindings)
        #expect(
            report.findings == [
                PolicyDiffRiskFinding(
                    kind: .verdictRelaxed,
                    severity: .blocking,
                    detail: "typed.git:gated deny->allow"
                )
            ]
        )
    }

    @Test func duplicateRowsRemovedNameTheStrictestRowOnly() {
        let existing = PolicyDocument(rules: [
            rule("first", verdict: .allow),
            rule("second", verdict: .deny),
        ])

        let report = replacement(existing: existing, incoming: PolicyDocument())

        #expect(
            report.findings == [
                PolicyDiffRiskFinding(
                    kind: .verdictRelaxed,
                    severity: .blocking,
                    detail: "typed.git:second deny->removed"
                )
            ]
        )
    }

    @Test func equalVerdictDuplicatesCollapseToTheFirstRow() {
        // Tie-break matches the tighten-only merges (`>` wins, ties
        // keep the earlier row): two deny rows for one predicate read
        // as the first, so a removal names it once.
        let existing = PolicyDocument(rules: [
            rule("first", verdict: .deny),
            rule("second", verdict: .deny),
        ])

        let report = replacement(existing: existing, incoming: PolicyDocument())

        #expect(
            report.findings == [
                PolicyDiffRiskFinding(
                    kind: .verdictRelaxed,
                    severity: .blocking,
                    detail: "typed.git:first deny->removed"
                )
            ]
        )
    }

    @Test func incomingDuplicateAllowThenDenyDoesNotReadAsRelaxed() {
        let existing = PolicyDocument(rules: [rule("gated", verdict: .deny)])
        let incoming = PolicyDocument(rules: [
            rule("first", verdict: .allow),
            rule("second", verdict: .deny),
        ])

        let report = replacement(existing: existing, incoming: incoming)

        #expect(report.findings.isEmpty)
    }

    @Test func exemptionWideningFollowsTheSeverityParameter() {
        let existing = PolicyDocument(allowPaths: ["/tmp/a"])
        let incoming = PolicyDocument(allowPaths: ["/tmp/a", "/tmp/b"])

        for severity: PolicyDiffRiskFinding.Severity in [.blocking, .advisory] {
            let report = replacement(
                existing: existing,
                incoming: incoming,
                severity: severity
            )
            #expect(
                report.findings == [
                    PolicyDiffRiskFinding(
                        kind: .newSecretExemption,
                        severity: severity,
                        detail: "/tmp/b"
                    )
                ],
                "wrong findings for severity \(severity)"
            )
            #expect(report.hasBlockingFindings == (severity == .blocking))
        }
    }

    @Test func evaluateKeepsExemptionAdvisory() {
        let report = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(allowPaths: ["/tmp/a"]),
            newDocument: PolicyDocument(allowPaths: ["/tmp/a", "/tmp/b"])
        )
        #expect(report.hasBlockingFindings == false)
        #expect(
            report.findings == [
                PolicyDiffRiskFinding(
                    kind: .newSecretExemption,
                    severity: .advisory,
                    detail: "/tmp/b"
                )
            ]
        )
    }

    @Test func replacementGateTable() {
        struct Case {
            let name: String
            let existing: PolicyDocument
            let incoming: PolicyDocument
            let expected: [PolicyDiffRiskFinding]
        }
        let cases: [Case] = [
            Case(
                name: "safety downgrade blocks",
                existing: PolicyDocument(safetyLevel: .strict),
                incoming: PolicyDocument(safetyLevel: .normal),
                expected: [
                    PolicyDiffRiskFinding(
                        kind: .safetyDowngrade,
                        severity: .blocking,
                        detail: "strict -> normal"
                    )
                ]
            ),
            Case(
                name: "removed ask blocks",
                existing: PolicyDocument(
                    rules: [rule("gated", verdict: .ask, on: otherPredicate)]
                ),
                incoming: PolicyDocument(),
                expected: [
                    PolicyDiffRiskFinding(
                        kind: .verdictRelaxed,
                        severity: .blocking,
                        detail: "typed.git:gated ask->removed"
                    )
                ]
            ),
            Case(
                name: "denied verdict relaxed to ask blocks",
                existing: PolicyDocument(rules: [rule("gated", verdict: .deny)]),
                incoming: PolicyDocument(rules: [rule("gated", verdict: .ask)]),
                expected: [
                    PolicyDiffRiskFinding(
                        kind: .verdictRelaxed,
                        severity: .blocking,
                        detail: "typed.git:gated deny->ask"
                    )
                ]
            ),
            Case(
                name: "dropping an allow narrows and stays silent",
                existing: PolicyDocument(rules: [rule("gated", verdict: .allow)]),
                incoming: PolicyDocument(),
                expected: []
            ),
            Case(
                name: "reviving an allow is advisory only",
                existing: PolicyDocument(),
                incoming: PolicyDocument(rules: [rule("gated", verdict: .allow)]),
                expected: [
                    PolicyDiffRiskFinding(
                        kind: .newAllowRule,
                        severity: .advisory,
                        detail: "typed.git:gated"
                    )
                ]
            ),
            Case(
                name: "tightening allow to deny is clean",
                existing: PolicyDocument(rules: [rule("gated", verdict: .allow)]),
                incoming: PolicyDocument(rules: [rule("gated", verdict: .deny)]),
                expected: []
            ),
        ]
        for entry in cases {
            let report = replacement(existing: entry.existing, incoming: entry.incoming)
            #expect(report.findings == entry.expected, "case: \(entry.name)")
        }
    }
}

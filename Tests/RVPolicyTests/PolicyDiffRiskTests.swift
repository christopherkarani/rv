import Testing
import RVDomain
import RVPolicy

struct PolicyDiffRiskTests {
    private func rule(
        _ pattern: String,
        verdict: TypedRuleVerdict,
        predicate: PolicyPredicate = .gitPush(force: .exactly(.force), branch: "main")
    ) -> PolicyDocumentRule {
        PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: pattern),
            verdict: verdict,
            predicate: predicate
        )
    }

    @Test func identicalDocumentsAreClean() {
        let document = PolicyDocument(
            rules: [rule("deny", verdict: .deny)],
            safetyLevel: .strict,
            allowPaths: ["/tmp/synthetic"]
        )
        let scope = PolicyNetworkScope(
            destinations: ["example.com"],
            binaries: ["/usr/bin/git"]
        )
        let report = PolicyDiffRisk.evaluate(
            oldDocument: document,
            newDocument: document,
            oldScope: scope,
            newScope: scope
        )
        #expect(report.findings.isEmpty)
        #expect(report.hasBlockingFindings == false)
        #expect(report.previewLines == ["risk: none"])
        #expect(report.findingLines.isEmpty)
    }

    @Test func newPublicDestinationIsAdvisoryAndDeterministic() {
        let first = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(),
            newScope: PolicyNetworkScope(destinations: ["b.example.com", "a.example.com"])
        )
        let second = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(),
            newScope: PolicyNetworkScope(destinations: ["a.example.com", "b.example.com"])
        )
        #expect(first == second)
        #expect(first.hasBlockingFindings == false)
        #expect(
            first.findings == [
                PolicyDiffRiskFinding(
                    kind: .newDestination,
                    severity: .advisory,
                    detail: "a.example.com"
                ),
                PolicyDiffRiskFinding(
                    kind: .newDestination,
                    severity: .advisory,
                    detail: "b.example.com"
                ),
            ]
        )
        #expect(first.previewLines[0] == "risk: 0 blocking, 2 advisory")
    }

    @Test func preexistingSensitiveDestinationIsNotFlagged() {
        let scope = PolicyNetworkScope(destinations: ["10.0.0.9"])
        let report = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(),
            oldScope: scope,
            newScope: scope
        )
        #expect(report.findings.isEmpty)
    }

    @Test func sensitiveRangesBlock() {
        let cases: [(String, String)] = [
            ("10.0.0.9", "private 10.0.0.9"),
            ("https://192.168.1.2:8443/hook", "private 192.168.1.2"),
            ("172.16.9.9", "private 172.16.9.9"),
            ("172.31.255.1", "private 172.31.255.1"),
            ("169.254.10.20", "link-local 169.254.10.20"),
            ("http://[fe80::1]/", "link-local fe80::1"),
            ("169.254.169.254", "metadata 169.254.169.254"),
            ("http://100.100.100.200/latest", "metadata 100.100.100.200"),
            ("metadata.google.internal", "metadata metadata.google.internal"),
            ("127.0.0.1:8080", "loopback 127.0.0.1"),
            ("https://[::1]/status", "loopback ::1"),
            ("localhost", "loopback localhost"),
            ("[fd00::5]", "private fd00::5"),
        ]
        for (destination, detail) in cases {
            let report = PolicyDiffRisk.evaluate(
                oldDocument: PolicyDocument(),
                newDocument: PolicyDocument(),
                newScope: PolicyNetworkScope(destinations: [destination])
            )
            #expect(report.hasBlockingFindings, "expected blocking for \(destination)")
            #expect(
                report.findings.contains(
                    PolicyDiffRiskFinding(
                        kind: .sensitiveRange,
                        severity: .blocking,
                        detail: detail
                    )
                ),
                "missing sensitive-range for \(destination)"
            )
        }
    }

    @Test func publicNeighborsAreNotSensitive() {
        for destination in ["172.15.0.1", "172.32.0.1", "169.253.1.1", "8.8.8.8", "example.com."] {
            let report = PolicyDiffRisk.evaluate(
                oldDocument: PolicyDocument(),
                newDocument: PolicyDocument(),
                newScope: PolicyNetworkScope(destinations: [destination])
            )
            #expect(report.hasBlockingFindings == false, "unexpected block for \(destination)")
        }
    }

    @Test func credentialBearingEndpointBlocksWithoutEchoingSecrets() {
        let report = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(),
            newScope: PolicyNetworkScope(destinations: ["https://robot:s3cret@example.com/hook"])
        )
        #expect(report.hasBlockingFindings)
        #expect(
            report.findings.contains(
                PolicyDiffRiskFinding(
                    kind: .credentialEndpoint,
                    severity: .blocking,
                    detail: "example.com"
                )
            )
        )
        for finding in report.findings {
            #expect(finding.detail.contains("s3cret") == false)
            #expect(finding.detail.contains("robot:") == false)
        }
    }

    @Test func unparseableDestinationFailsClosed() {
        for destination in ["", "https://", "https://[::1", "https://user@", "not a host!! with spaces"] {
            let report = PolicyDiffRisk.evaluate(
                oldDocument: PolicyDocument(),
                newDocument: PolicyDocument(),
                newScope: PolicyNetworkScope(destinations: [destination])
            )
            #expect(report.hasBlockingFindings, "expected block for \(destination)")
            #expect(
                report.findings.contains(where: { $0.kind == .unparseableDestination }),
                "missing unparseable-destination for \(destination)"
            )
        }
        let credentialed = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(),
            newScope: PolicyNetworkScope(destinations: ["https://user:pw@"])
        )
        for finding in credentialed.findings where finding.kind == .unparseableDestination {
            #expect(finding.detail.contains("pw") == false)
        }
    }

    @Test func binaryScopeWidening() {
        let added = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(),
            oldScope: PolicyNetworkScope(binaries: ["/usr/bin/git"]),
            newScope: PolicyNetworkScope(binaries: ["/usr/bin/git", "/usr/bin/ssh"])
        )
        #expect(added.hasBlockingFindings == false)
        #expect(
            added.findings == [
                PolicyDiffRiskFinding(
                    kind: .binaryAdded,
                    severity: .advisory,
                    detail: "/usr/bin/ssh"
                )
            ]
        )
        let wildcard = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(),
            newScope: PolicyNetworkScope(binaries: ["/usr/bin/*"])
        )
        #expect(wildcard.hasBlockingFindings)
        #expect(
            wildcard.findings.contains(
                PolicyDiffRiskFinding(
                    kind: .binaryWildcard,
                    severity: .blocking,
                    detail: "/usr/bin/*"
                )
            )
        )
    }

    @Test func safetyDowngradeBlocks() {
        let downgrade = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(safetyLevel: .strict),
            newDocument: PolicyDocument(safetyLevel: .normal)
        )
        #expect(downgrade.hasBlockingFindings)
        #expect(
            downgrade.findings.contains(
                PolicyDiffRiskFinding(
                    kind: .safetyDowngrade,
                    severity: .blocking,
                    detail: "strict -> normal"
                )
            )
        )
        let unset = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(safetyLevel: .strict),
            newDocument: PolicyDocument()
        )
        #expect(
            unset.findings.contains(
                PolicyDiffRiskFinding(
                    kind: .safetyDowngrade,
                    severity: .blocking,
                    detail: "strict -> unset"
                )
            )
        )
        let upgrade = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(safetyLevel: .strict)
        )
        #expect(upgrade.findings.isEmpty)
    }

    @Test func ruleChanges() {
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        let addedAllow = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(rules: [rule("allow", verdict: .allow, predicate: predicate)])
        )
        #expect(addedAllow.hasBlockingFindings == false)
        #expect(
            addedAllow.findings == [
                PolicyDiffRiskFinding(
                    kind: .newAllowRule,
                    severity: .advisory,
                    detail: "typed.git:allow"
                )
            ]
        )
        let addedDeny = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(rules: [rule("deny", verdict: .deny, predicate: predicate)])
        )
        #expect(addedDeny.findings.isEmpty)
        let relaxed = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(rules: [rule("deny", verdict: .deny, predicate: predicate)]),
            newDocument: PolicyDocument(rules: [rule("allow", verdict: .allow, predicate: predicate)])
        )
        #expect(relaxed.hasBlockingFindings)
        #expect(
            relaxed.findings.contains(
                PolicyDiffRiskFinding(
                    kind: .verdictRelaxed,
                    severity: .blocking,
                    detail: "typed.git:allow deny->allow"
                )
            )
        )
        let tightened = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(rules: [rule("allow", verdict: .allow, predicate: predicate)]),
            newDocument: PolicyDocument(rules: [rule("deny", verdict: .deny, predicate: predicate)])
        )
        #expect(tightened.findings.isEmpty)
    }

    @Test func newSecretExemptionIsAdvisory() {
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

    @Test func duplicateInputsDeduplicate() {
        let report = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(),
            newDocument: PolicyDocument(),
            newScope: PolicyNetworkScope(destinations: ["example.com", "example.com"])
        )
        #expect(
            report.findings == [
                PolicyDiffRiskFinding(
                    kind: .newDestination,
                    severity: .advisory,
                    detail: "example.com"
                )
            ]
        )
    }

    @Test func textEntryFailsClosedOnUnparseableDiff() throws {
        let valid = "schema_version = 1\n"
        let oldReport = try PolicyDiffRisk.evaluate(oldText: valid, newText: valid)
        #expect(oldReport.findings.isEmpty)
        #expect(throws: PolicyDiffRiskError.unparseableDiff(side: .old)) {
            _ = try PolicyDiffRisk.evaluate(oldText: "not-toml", newText: valid)
        }
        #expect(throws: PolicyDiffRiskError.unparseableDiff(side: .new)) {
            _ = try PolicyDiffRisk.evaluate(oldText: valid, newText: "not-toml")
        }
    }

    @Test func removedProtectiveRuleBlocks() {
        let denyPredicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        let askPredicate = PolicyPredicate.gitDiscardWorktree(pathspec: nil)
        let allowPredicate = PolicyPredicate.gitReset(mode: nil)
        let report = PolicyDiffRisk.evaluate(
            oldDocument: PolicyDocument(rules: [
                rule("deny", verdict: .deny, predicate: denyPredicate),
                rule("ask", verdict: .ask, predicate: askPredicate),
                rule("allow", verdict: .allow, predicate: allowPredicate),
            ]),
            newDocument: PolicyDocument()
        )
        #expect(report.hasBlockingFindings)
        #expect(
            report.findings.contains(
                PolicyDiffRiskFinding(
                    kind: .verdictRelaxed,
                    severity: .blocking,
                    detail: "typed.git:deny deny->removed"
                )
            )
        )
        #expect(
            report.findings.contains(
                PolicyDiffRiskFinding(
                    kind: .verdictRelaxed,
                    severity: .blocking,
                    detail: "typed.git:ask ask->removed"
                )
            )
        )
        #expect(report.findings.contains(where: { $0.detail.contains("typed.git:allow") }) == false)
    }

    @Test func shareSemanticsFlagRelaxationAsksButNotOmissions() {
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        let other = PolicyPredicate.gitDiscardWorktree(pathspec: nil)
        let existing = PolicyDocument(rules: [rule("deny", verdict: .deny, predicate: predicate)])

        let relaxed = PolicyDiffRisk.evaluateShare(
            existing: existing,
            incoming: PolicyDocument(rules: [rule("allow", verdict: .allow, predicate: predicate)])
        )
        #expect(relaxed.hasBlockingFindings)
        #expect(
            relaxed.findings == [
                PolicyDiffRiskFinding(
                    kind: .verdictRelaxed,
                    severity: .blocking,
                    detail: "typed.git:allow deny->allow"
                )
            ]
        )

        // A partial share omits most of the layer; omission preserves.
        let omission = PolicyDiffRisk.evaluateShare(
            existing: existing,
            incoming: PolicyDocument(rules: [rule("extra", verdict: .allow, predicate: other)])
        )
        #expect(omission.hasBlockingFindings == false)
        #expect(
            omission.findings == [
                PolicyDiffRiskFinding(
                    kind: .newAllowRule,
                    severity: .advisory,
                    detail: "typed.git:extra"
                )
            ]
        )

        let tightened = PolicyDiffRisk.evaluateShare(
            existing: PolicyDocument(rules: [rule("allow", verdict: .allow, predicate: predicate)]),
            incoming: PolicyDocument(rules: [rule("deny", verdict: .deny, predicate: predicate)])
        )
        #expect(tightened.findings.isEmpty)
    }

    @Test func numericIPv4AliasesAreClassified() {
        let cases: [(String, String)] = [
            ("2130706433", "loopback 2130706433"),
            ("0x7f000001", "loopback 0x7f000001"),
            ("017700000001", "loopback 017700000001"),
            ("0x7f.0.0.1", "loopback 0x7f.0.0.1"),
            ("0177.0.0.1", "loopback 0177.0.0.1"),
            ("127.1", "loopback 127.1"),
            ("0x7f.1", "loopback 0x7f.1"),
            ("http://2130706433:8080/status", "loopback 2130706433"),
            ("3232235521", "private 3232235521"),
            ("0xa.0.0.1", "private 0xa.0.0.1"),
            ("2852039166", "metadata 2852039166"),
            ("0xa9fea9fe", "metadata 0xa9fea9fe"),
        ]
        for (destination, detail) in cases {
            let report = PolicyDiffRisk.evaluate(
                oldDocument: PolicyDocument(),
                newDocument: PolicyDocument(),
                newScope: PolicyNetworkScope(destinations: [destination])
            )
            #expect(report.hasBlockingFindings, "expected blocking for \(destination)")
            #expect(
                report.findings.contains(
                    PolicyDiffRiskFinding(
                        kind: .sensitiveRange,
                        severity: .blocking,
                        detail: detail
                    )
                ),
                "missing sensitive-range for \(destination)"
            )
        }
    }

    @Test func publicNumericFormsAndInvalidNumericsStayAdvisory() {
        for destination in ["134744072", "0x8080808", "8.8.8.8", "999.1.1.1", "1.2.3.256", "0xZZZ", "1.2.3.4.5"] {
            let report = PolicyDiffRisk.evaluate(
                oldDocument: PolicyDocument(),
                newDocument: PolicyDocument(),
                newScope: PolicyNetworkScope(destinations: [destination])
            )
            #expect(report.hasBlockingFindings == false, "unexpected block for \(destination)")
            #expect(
                report.findings.contains(where: { $0.kind == .newDestination }),
                "missing advisory for \(destination)"
            )
        }
    }
}

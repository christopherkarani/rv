import Foundation
import Testing
import RVDomain
import RVPolicy

/// Seam gate: every rollback path refuses (`blockedByFindings`, before
/// anything is written) a restore that drops a live deny or ask, relaxes
/// a surviving predicate's verdict, downgrades the safety level, or widens
/// secret exemptions. The existing side is the live policy file
/// enforcement loads. Dropping an allow is narrowing and still succeeds.
@Suite("RollbackRiskGate")
struct RollbackRiskGateTests {
    @Test func machineRollbackRefusesVerdictRelaxation() throws {
        let root = try isolatedGateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        try store.saveMachine(PolicyDocument(rules: [gateRule(predicate, verdict: .allow)]))
        try store.saveMachine(PolicyDocument(rules: [gateRule(predicate, verdict: .deny)]))
        let live = try store.loadMachineDocument()

        try expectBlocked {
            try store.rollbackMachine(to: 1)
        }

        #expect(try store.loadMachineDocument() == live)
        #expect(try store.listMachineRevisions().map(\.revision) == [1, 2])
    }

    @Test func verifiedRollbackRefusesVerdictRelaxation() throws {
        let root = try isolatedGateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        try store.saveMachine(PolicyDocument(rules: [gateRule(predicate, verdict: .allow)]))
        try store.saveMachine(PolicyDocument(rules: [gateRule(predicate, verdict: .deny)]))
        let live = try store.loadMachineDocument()

        try expectBlocked {
            try store.rollbackMachine(toRevision: 1)
        }

        #expect(try store.loadMachineDocument() == live)
        #expect(try store.machineHistory().map(\.revision) == [1, 2])
    }

    @Test func repoRollbackRefusesVerdictRelaxation() throws {
        let config = try isolatedGateDirectory()
        let workspace = try isolatedGateDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        try store.saveRepo(
            PolicyDocument(rules: [gateRule(predicate, verdict: .allow)]),
            workspace: workspace
        )
        try store.saveRepo(
            PolicyDocument(rules: [gateRule(predicate, verdict: .deny)]),
            workspace: workspace
        )
        let live = try store.loadRepoDocument(workspace: workspace)

        try expectBlocked {
            try store.rollbackRepo(to: 1, workspace: workspace)
        }

        #expect(try store.loadRepoDocument(workspace: workspace) == live)
        #expect(try store.listRepoRevisions(workspace: workspace).map(\.revision) == [1, 2])
    }

    @Test func rollbackDroppingADenyIsRefused() throws {
        // Deleting a deny widens enforcement. Restoring generation 1 must
        // refuse and leave the head that still carries the deny.
        let root = try isolatedGateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let keep = protectiveRule("keep", verdict: .deny, predicate: .gitPush(force: .exactly(.force), branch: "main"))
        let dropped = protectiveRule("dropped", verdict: .deny, predicate: .gitDiscardWorktree(pathspec: nil))
        try store.saveMachine(PolicyDocument(rules: [keep]))
        try store.saveMachine(PolicyDocument(rules: [keep, dropped]))
        let live = try store.loadMachineDocument()

        let report = try expectBlockedReport {
            try store.rollbackMachine(to: 1)
        }

        #expect(report.blockingFindings.contains {
            $0.kind == .verdictRelaxed && $0.detail == "core.git:dropped deny->removed"
        })
        #expect(try store.loadMachineDocument() == live)
        #expect(try store.listMachineRevisions().map(\.revision) == [1, 2])
    }

    @Test func rollbackDroppingAnAskIsRefused() throws {
        let root = try isolatedGateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let keep = protectiveRule("keep", verdict: .deny, predicate: .gitPush(force: .exactly(.force), branch: "main"))
        let dropped = protectiveRule("dropped", verdict: .ask, predicate: .gitDiscardWorktree(pathspec: nil))
        try store.saveMachine(PolicyDocument(rules: [keep]))
        try store.saveMachine(PolicyDocument(rules: [keep, dropped]))
        let live = try store.loadMachineDocument()

        let report = try expectBlockedReport {
            try store.rollbackMachine(toRevision: 1)
        }

        #expect(report.blockingFindings.contains {
            $0.kind == .verdictRelaxed && $0.detail == "core.git:dropped ask->removed"
        })
        #expect(try store.loadMachineDocument() == live)
        #expect(try store.machineHistory().map(\.revision) == [1, 2])
    }

    @Test func repoRollbackDroppingADenyIsRefused() throws {
        let config = try isolatedGateDirectory()
        let workspace = try isolatedGateDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        let keep = protectiveRule("keep", verdict: .deny, predicate: .gitPush(force: .exactly(.force), branch: "main"))
        let dropped = protectiveRule("dropped", verdict: .deny, predicate: .gitDiscardWorktree(pathspec: nil))
        try store.saveRepo(PolicyDocument(rules: [keep]), workspace: workspace)
        try store.saveRepo(PolicyDocument(rules: [keep, dropped]), workspace: workspace)
        let live = try store.loadRepoDocument(workspace: workspace)

        let report = try expectBlockedReport {
            try store.rollbackRepo(to: 1, workspace: workspace)
        }

        #expect(report.blockingFindings.contains {
            $0.kind == .verdictRelaxed && $0.detail == "core.git:dropped deny->removed"
        })
        #expect(try store.loadRepoDocument(workspace: workspace) == live)
        #expect(try store.listRepoRevisions(workspace: workspace).map(\.revision) == [1, 2])
    }

    @Test func rollbackRefusesDenyEditedIntoTheLiveFile() throws {
        // The sealed predicate set never contains the planted deny. A gate
        // that compares the sealed tail would restore revision 2 and erase
        // the rule enforcement is loading from policy.toml.
        let root = try isolatedGateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let keep = protectiveRule("keep", verdict: .deny, predicate: .gitPush(force: .exactly(.force), branch: "main"))
        let narrowing = protectiveRule("narrowing", verdict: .allow, predicate: .gitReset(mode: nil))
        let planted = protectiveRule("planted", verdict: .deny, predicate: .gitDiscardWorktree(pathspec: nil))
        try store.saveMachine(PolicyDocument(rules: [keep]))
        try store.saveMachine(PolicyDocument(rules: [keep, narrowing]))
        var liveDocument = PolicyDocument(rules: [keep, narrowing, planted])
        liveDocument.safetyLevel = .strict
        try Data(PolicyDocumentTOML.render(liveDocument).utf8).write(to: store.machineFileURL)
        let liveBytes = try Data(contentsOf: store.machineFileURL)

        let report = try expectBlockedReport {
            try store.rollbackMachine(toRevision: 2)
        }

        #expect(report.blockingFindings.contains {
            $0.kind == .verdictRelaxed && $0.detail == "core.git:planted deny->removed"
        })
        #expect(report.blockingFindings.contains { $0.kind == .safetyDowngrade })
        #expect(try Data(contentsOf: store.machineFileURL) == liveBytes)
        #expect(try store.loadMachineDocument() == liveDocument)
        #expect(try store.listMachineRevisions().map(\.revision) == [1, 2])
    }

    @Test func repoRollbackRefusesDenyEditedIntoTheLiveFile() throws {
        let config = try isolatedGateDirectory()
        let workspace = try isolatedGateDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        let keep = protectiveRule("keep", verdict: .deny, predicate: .gitPush(force: .exactly(.force), branch: "main"))
        let narrowing = protectiveRule("narrowing", verdict: .allow, predicate: .gitReset(mode: nil))
        let planted = protectiveRule("planted", verdict: .ask, predicate: .gitDiscardWorktree(pathspec: nil))
        try store.saveRepo(PolicyDocument(rules: [keep]), workspace: workspace)
        try store.saveRepo(PolicyDocument(rules: [keep, narrowing]), workspace: workspace)
        var liveDocument = PolicyDocument(rules: [keep, narrowing, planted])
        liveDocument.safetyLevel = .strict
        let file = TypedRuleStore.repoFileURL(workspace: workspace)
        try Data(PolicyDocumentTOML.render(liveDocument).utf8).write(to: file)
        let liveBytes = try Data(contentsOf: file)

        let report = try expectBlockedReport {
            try store.rollbackRepo(to: 2, workspace: workspace)
        }

        #expect(report.blockingFindings.contains {
            $0.kind == .verdictRelaxed && $0.detail == "core.git:planted ask->removed"
        })
        #expect(report.blockingFindings.contains { $0.kind == .safetyDowngrade })
        #expect(try Data(contentsOf: file) == liveBytes)
        #expect(try store.loadRepoDocument(workspace: workspace) == liveDocument)
        #expect(try store.listRepoRevisions(workspace: workspace).map(\.revision) == [1, 2])
    }

    @Test func rollbackRefusesSafetyDowngrade() throws {
        let root = try isolatedGateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        try store.saveMachine(PolicyDocument(rules: [gateRule(predicate, verdict: .deny)]))
        var strict = PolicyDocument(rules: [gateRule(predicate, verdict: .deny)])
        strict.safetyLevel = .strict
        try store.saveMachine(strict)
        let live = try store.loadMachineDocument()

        do {
            _ = try store.rollbackMachine(to: 1)
            #expect(Bool(false), "expected blockedByFindings")
        } catch let error as PolicyDiffRiskError {
            guard case .blockedByFindings(let report) = error else { throw error }
            #expect(report.blockingFindings.contains { $0.kind == .safetyDowngrade })
        }
        #expect(try store.loadMachineDocument() == live)
    }

    @Test func rollbackRefusesExemptionWidening() throws {
        let root = try isolatedGateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        var wide = PolicyDocument(rules: [gateRule(predicate, verdict: .deny)])
        wide.allowPaths = ["~/.ssh/id_rsa"]
        try store.saveMachine(wide)
        try store.saveMachine(PolicyDocument(rules: [gateRule(predicate, verdict: .deny)]))
        let live = try store.loadMachineDocument()

        do {
            _ = try store.rollbackMachine(to: 1)
            #expect(Bool(false), "expected blockedByFindings")
        } catch let error as PolicyDiffRiskError {
            guard case .blockedByFindings(let report) = error else { throw error }
            #expect(report.blockingFindings.contains { $0.kind == .newSecretExemption })
        }
        #expect(try store.loadMachineDocument() == live)
    }

    @Test func rollbackDroppingAnAllowRuleStillSucceeds() throws {
        // Removing an allow narrows; the gate must not block tightening
        // restores.
        let root = try isolatedGateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let keep = PolicyDocumentRule(
            id: RuleID(pack: .coreGit, pattern: "keep"),
            verdict: .deny,
            predicate: .gitPush(force: .exactly(.force), branch: "main")
        )
        let dropped = PolicyDocumentRule(
            id: RuleID(pack: .coreGit, pattern: "dropped"),
            verdict: .allow,
            predicate: .gitDiscardWorktree(pathspec: nil)
        )
        try store.saveMachine(PolicyDocument(rules: [keep]))
        try store.saveMachine(PolicyDocument(rules: [keep, dropped]))

        let head = try store.rollbackMachine(to: 1)

        #expect(head.revision == 3)
        #expect(try store.loadMachineDocument().rules == [keep])
    }
}

private func protectiveRule(
    _ pattern: String,
    verdict: TypedRuleVerdict,
    predicate: PolicyPredicate
) -> PolicyDocumentRule {
    PolicyDocumentRule(
        id: RuleID(pack: .coreGit, pattern: pattern),
        verdict: verdict,
        predicate: predicate
    )
}

private func gateRule(
    _ predicate: PolicyPredicate,
    verdict: TypedRuleVerdict
) -> PolicyDocumentRule {
    PolicyDocumentRule(
        id: RuleID(pack: .coreGit, pattern: "gated"),
        verdict: verdict,
        predicate: predicate
    )
}

private func expectBlocked(_ operation: () throws -> Void) throws {
    let report = try expectBlockedReport(operation)
    #expect(report.blockingFindings.allSatisfy { $0.kind == .verdictRelaxed })
}

private func expectBlockedReport(_ operation: () throws -> Void) throws -> PolicyDiffRiskReport {
    do {
        try operation()
    } catch let error as PolicyDiffRiskError {
        guard case .blockedByFindings(let report) = error else {
            throw error
        }
        #expect(report.hasBlockingFindings)
        return report
    }
    #expect(Bool(false), "expected blockedByFindings")
    return PolicyDiffRiskReport(findings: [])
}

private func isolatedGateDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-rollback-gate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

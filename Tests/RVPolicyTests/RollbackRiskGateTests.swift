import Foundation
import Testing
import RVDomain
import RVPolicy

/// Seam gate: every rollback path refuses (`blockedByFindings`, before
/// anything is written) a restore that relaxes a surviving predicate's
/// verdict, downgrades the safety level, or widens secret exemptions.
/// Predicate-set change is the rollback operation itself and passes:
/// restoring an earlier generation necessarily drops predicates the head
/// added.
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

    @Test func rollbackDroppingARuleStillSucceeds() throws {
        // Predicate-set change is the rollback operation itself: restoring
        // generation 1 necessarily drops the deny generation 2 added.
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
            verdict: .deny,
            predicate: .gitDiscardWorktree(pathspec: nil)
        )
        try store.saveMachine(PolicyDocument(rules: [keep]))
        try store.saveMachine(PolicyDocument(rules: [keep, dropped]))

        let head = try store.rollbackMachine(to: 1)

        #expect(head.revision == 3)
        #expect(try store.loadMachineDocument().rules == [keep])
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
    do {
        try operation()
    } catch let error as PolicyDiffRiskError {
        guard case .blockedByFindings(let report) = error else {
            throw error
        }
        #expect(report.hasBlockingFindings)
        #expect(report.blockingFindings.allSatisfy { $0.kind == .verdictRelaxed })
        return
    }
    #expect(Bool(false), "expected blockedByFindings")
}

private func isolatedGateDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-rollback-gate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// Read-only rollback preview: names the revision a rollback would restore,
/// the current head, and the exact risk report the rollback gate would
/// judge, without writing anything. Same errors as the rollback itself.
@Suite("RollbackPreview")
struct RollbackPreviewTests {
    @Test func machinePreviewNamesTargetAndHeadWithoutWriting() throws {
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [previewDeny]))
        try store.saveMachine(PolicyDocument(rules: [previewDeny, previewAllow]))
        let before = try directorySnapshot(root)

        let preview = try store.previewMachineRollback(to: 1)

        let entries = try store.listMachineRevisions()
        #expect(preview.target == entries[0])
        #expect(preview.head == entries[1])
        #expect(preview.live == PolicyDocument(rules: [previewDeny, previewAllow]))
        #expect(preview.risk.hasBlockingFindings == false)
        #expect(try directorySnapshot(root) == before)
    }

    @Test func machinePreviewReportsTheFindingsTheRollbackRefusesWith() throws {
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [previewAllowOn(previewDeny.predicate)]))
        try store.saveMachine(PolicyDocument(rules: [previewDeny]))
        let before = try directorySnapshot(root)

        let preview = try store.previewMachineRollback(to: 1)

        #expect(preview.risk.hasBlockingFindings)
        #expect(try directorySnapshot(root) == before)
        do {
            _ = try store.rollbackMachine(to: 1)
            Issue.record("expected blockedByFindings")
        } catch PolicyDiffRiskError.blockedByFindings(let refused) {
            #expect(preview.risk.blockingFindings == refused.blockingFindings)
        }
    }

    @Test func previewJudgesTheLiveFileToo() throws {
        // A deny edited into policy.toml after the last save is part of the
        // posture the restore would replace: preview flags it like rollback.
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [previewAllow]))
        try store.saveMachine(PolicyDocument(rules: []))
        try PolicyDocumentTOML.render(PolicyDocument(rules: [previewDeny]))
            .write(to: store.machineFileURL, atomically: true, encoding: .utf8)

        let preview = try store.previewMachineRollback(to: 1)

        #expect(preview.risk.hasBlockingFindings)
        #expect(throws: PolicyDiffRiskError.self) { _ = try store.rollbackMachine(to: 1) }
    }

    @Test func unparseableLiveFileIsGatedAgainstTheHeadAlone() throws {
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [previewDeny]))
        try store.saveMachine(PolicyDocument(rules: [previewDeny, previewAllow]))
        try "not = [valid".write(to: store.machineFileURL, atomically: true, encoding: .utf8)

        let preview = try store.previewMachineRollback(to: 1)

        #expect(preview.live == nil)
        #expect(preview.risk.hasBlockingFindings == false)
    }

    @Test func unknownMachineRevisionThrows() throws {
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)

        #expect(throws: TypedRuleStoreError.unknownRevision) { _ = try store.previewMachineRollback(to: 1) }
        #expect(FileManager.default.fileExists(atPath: store.machineFileURL.path) == false)
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)

        try store.saveMachine(PolicyDocument(rules: [previewDeny]))
        for revision in [0, -1, 2, 99] {
            #expect(throws: TypedRuleStoreError.unknownRevision) {
                _ = try store.previewMachineRollback(to: revision)
            }
        }
    }

    @Test func forgedMachineLogFailsClosed() throws {
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [previewDeny]))
        try store.saveMachine(PolicyDocument(rules: [previewDeny, previewAllow]))
        let lines = try String(contentsOf: store.machineRevisionsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        try (String(lines[0]) + "\n").write(to: store.machineRevisionsURL, atomically: true, encoding: .utf8)

        #expect(throws: TypedRuleStoreError.logCorrupted) { _ = try store.previewMachineRollback(to: 1) }
    }

    @Test func deletedMachineLogFailsClosed() throws {
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [previewDeny]))
        try FileManager.default.removeItem(at: store.machineRevisionsURL)

        #expect(throws: TypedRuleStoreError.logMissing) { _ = try store.previewMachineRollback(to: 1) }
    }

    @Test func repoPreviewNamesTargetAndHeadWithoutWriting() throws {
        let config = try isolatedPreviewDirectory()
        let workspace = try isolatedPreviewDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        try store.saveRepo(PolicyDocument(rules: [previewAllowOn(previewDeny.predicate)]), workspace: workspace)
        try store.saveRepo(PolicyDocument(rules: [previewDeny]), workspace: workspace)
        let configBefore = try directorySnapshot(config)
        let workspaceBefore = try directorySnapshot(workspace)

        let preview = try store.previewRepoRollback(to: 1, workspace: workspace)

        let entries = try store.listRepoRevisions(workspace: workspace)
        #expect(preview.target == entries[0])
        #expect(preview.head == entries[1])
        #expect(preview.risk.hasBlockingFindings)
        #expect(try directorySnapshot(config) == configBefore)
        #expect(try directorySnapshot(workspace) == workspaceBefore)
        #expect(throws: TypedRuleStoreError.unknownRevision) {
            _ = try store.previewRepoRollback(to: 3, workspace: workspace)
        }
    }

    @Test func workspacePreviewDiffsEffectiveRules() throws {
        let config = try isolatedPreviewDirectory()
        let workspace = try isolatedPreviewDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let session = PolicyWorkspace(configDirectory: config, workspace: workspace)
        try session.upsert(previewDeny, layer: .machine)
        try session.upsert(previewAllow, layer: .machine)
        try session.upsert(previewAsk, layer: .repo)

        let preview = try session.previewRollback(layer: .machine, to: 1)

        #expect(preview.layer == .machine)
        #expect(preview.target.revision == 1)
        #expect(preview.head.revision == 2)
        let current = try #require(preview.currentEffective)
        let restored = try #require(preview.restoredEffective)
        #expect(current == (try session.loadEffectiveRules()))
        #expect(restored.map(\.predicate) == [previewDeny.predicate, previewAsk.predicate])
        #expect(restored.contains { $0.predicate == previewAllow.predicate } == false)

        let repo = try session.previewRollback(layer: .repo, to: 1)
        #expect(repo.layer == .repo)
        #expect(throws: TypedRuleStoreError.unknownRevision) {
            _ = try session.previewRollback(layer: .repo, to: 2)
        }
    }

    @Test func workspaceRepoPreviewRefusesWithoutMachineDirectory() throws {
        let workspace = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let session = PolicyWorkspace(home: nil, workspace: workspace)

        #expect(throws: PolicyWorkspaceError.missingLayer(.machine)) {
            _ = try session.previewRollback(layer: .repo, to: 1)
        }
    }
}

private let previewDeny = PolicyDocumentRule(
    id: RuleID(pack: .coreGit, pattern: "force-push-main"),
    verdict: .deny,
    predicate: .gitPush(force: .exactly(.force), branch: "main")
)

private let previewAllow = PolicyDocumentRule(
    id: RuleID(pack: .typedGit, pattern: "discard-allow"),
    verdict: .allow,
    predicate: .gitDiscardWorktree(pathspec: nil)
)

private let previewAsk = PolicyDocumentRule(
    id: RuleID(pack: .typedGit, pattern: "reset-ask"),
    verdict: .ask,
    predicate: .gitReset(mode: nil)
)

private func previewAllowOn(_ predicate: PolicyPredicate) -> PolicyDocumentRule {
    PolicyDocumentRule(id: RuleID(pack: .coreGit, pattern: "force-push-main"), verdict: .allow, predicate: predicate)
}

/// Every file under `root` with its bytes: a preview must change none.
private func directorySnapshot(_ root: URL) throws -> [String: Data] {
    var snapshot: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == true {
            snapshot[url.path] = try Data(contentsOf: url)
        }
    }
    return snapshot
}

private func isolatedPreviewDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-rollback-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

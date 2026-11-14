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

    @Test func repoPreviewWithDeletedRvDirectoryCreatesNothing() throws {
        let config = try isolatedPreviewDirectory()
        let workspace = try isolatedPreviewDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        try store.saveRepo(PolicyDocument(rules: [previewAllow]), workspace: workspace)
        try store.saveRepo(PolicyDocument(rules: []), workspace: workspace)
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(".rv", isDirectory: true))
        let configBefore = try directorySnapshot(config)
        let workspaceBefore = try directorySnapshot(workspace)

        let preview = try store.previewRepoRollback(to: 1, workspace: workspace)

        #expect(preview.target.revision == 1)
        #expect(try directorySnapshot(config) == configBefore)
        #expect(try directorySnapshot(workspace) == workspaceBefore)
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".rv").path) == false)
    }

    @Test func machinePreviewWithoutLogsCreatesNoLockFiles() throws {
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try PolicyDocumentTOML.render(PolicyDocument(rules: [previewDeny]))
            .write(to: store.machineFileURL, atomically: true, encoding: .utf8)
        let before = try directorySnapshot(root)

        #expect(throws: TypedRuleStoreError.logMissing) { _ = try store.previewMachineRollback(to: 1) }

        #expect(try directorySnapshot(root) == before)
    }

    @Test func repoPreviewKeepsAnExistingRvDirectoryMode() throws {
        let config = try isolatedPreviewDirectory()
        let workspace = try isolatedPreviewDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        try store.saveRepo(PolicyDocument(rules: [previewDeny]), workspace: workspace)
        let rv = workspace.appendingPathComponent(".rv", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rv.path)
        let before = try directorySnapshot(workspace)

        _ = try store.previewRepoRollback(to: 1, workspace: workspace)

        #expect(try directorySnapshot(workspace) == before)
        let mode = try FileManager.default.attributesOfItem(atPath: rv.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
    }

    @Test func rollbackBoundToAStaleHeadRefusesWithoutWriting() throws {
        let config = try isolatedPreviewDirectory()
        let workspace = try isolatedPreviewDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let session = PolicyWorkspace(configDirectory: config, workspace: workspace)
        try session.upsert(previewDeny, layer: .machine)
        try session.upsert(previewAllow, layer: .machine)
        try session.upsert(previewDeny, layer: .repo)
        try session.upsert(previewAllow, layer: .repo)
        for layer in [PolicyDocumentLayer.machine, .repo] {
            let preview = try session.previewRollback(layer: layer, to: 1)
            // Another save lands between the preview and the approved write.
            try session.upsert(previewAsk, layer: layer)
            let before = try directorySnapshot(config).merging(try directorySnapshot(workspace)) { a, _ in a }

            #expect(throws: TypedRuleStoreError.headChanged) {
                _ = try session.rollback(layer: layer, to: 1, expected: binding(preview))
            }

            let after = try directorySnapshot(config).merging(try directorySnapshot(workspace)) { a, _ in a }
            #expect(after == before)
            #expect(try session.listRevisions(layer: layer).count == 3)
        }
    }

    @Test func rollbackBoundToAnotherTargetRefusesWithoutWriting() throws {
        let config = try isolatedPreviewDirectory()
        let workspace = try isolatedPreviewDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let session = PolicyWorkspace(configDirectory: config, workspace: workspace)
        for layer in [PolicyDocumentLayer.machine, .repo] {
            try session.upsert(previewDeny, layer: layer)
            try session.upsert(previewAllow, layer: layer)
            let preview = try session.previewRollback(layer: layer, to: 1)
            var wrongHash = binding(preview)
            wrongHash.target.hash = String(repeating: "0", count: 64)
            var wrongRevision = binding(preview)
            wrongRevision.target.revision = 2
            let before = try directorySnapshot(config).merging(try directorySnapshot(workspace)) { a, _ in a }

            for stale in [wrongHash, wrongRevision] {
                #expect(throws: TypedRuleStoreError.headChanged) {
                    _ = try session.rollback(layer: layer, to: 1, expected: stale)
                }
            }

            let after = try directorySnapshot(config).merging(try directorySnapshot(workspace)) { a, _ in a }
            #expect(after == before)
        }
    }

    @Test func aStaleBindingDoesNotSealAnInterruptedSave() throws {
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [previewDeny]))
        try store.saveMachine(PolicyDocument(rules: [previewDeny, previewAllow]))
        let preview = try store.previewMachineRollback(to: 1)
        // A save of r3 crashed after policy.toml and the display line, before the seal.
        let third = PolicyDocument(rules: [previewDeny, previewAllow, previewAsk])
        let thirdText = PolicyDocumentTOML.render(third)
        try thirdText.write(to: store.machineFileURL, atomically: true, encoding: .utf8)
        let tail = PolicyRevision(
            revision: 3, hash: PolicyRevisionIdentity.hash(third), ruleCount: third.rules.count,
            recordedAt: Date(), toml: thirdText, document: third
        )
        let handle = try FileHandle(forWritingTo: store.machineRevisionsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONEncoder().encode(tail) + Data("\n".utf8))
        try handle.close()
        let before = try directorySnapshot(root)

        #expect(throws: TypedRuleStoreError.headChanged) {
            _ = try store.rollbackMachine(to: 1, expected: PolicyRollbackBinding(target: preview.target, head: preview.head))
        }

        #expect(try directorySnapshot(root) == before)
    }

    @Test func aBoundRollbackOnATruncatedDisplayLogReportsCorruption() throws {
        let root = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine(PolicyDocument(rules: [previewDeny]))
        try store.saveMachine(PolicyDocument(rules: [previewDeny, previewAllow]))
        try store.saveMachine(PolicyDocument(rules: [previewDeny, previewAllow, previewAsk]))
        let preview = try store.previewMachineRollback(to: 1)
        let lines = try String(contentsOf: store.machineRevisionsURL, encoding: .utf8)
            .split(separator: "\n").prefix(2).joined(separator: "\n") + "\n"
        try lines.write(to: store.machineRevisionsURL, atomically: true, encoding: .utf8)
        let before = try directorySnapshot(root)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            _ = try store.rollbackMachine(to: 1, expected: PolicyRollbackBinding(target: preview.target, head: preview.head))
        }

        #expect(try directorySnapshot(root) == before)
    }

    @Test func rollbackBoundToTheCurrentHeadProceeds() throws {
        let config = try isolatedPreviewDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        let session = PolicyWorkspace(configDirectory: config, workspace: nil)
        try session.upsert(previewDeny, layer: .machine)
        try session.upsert(previewAllow, layer: .machine)
        let preview = try session.previewRollback(layer: .machine, to: 1)

        let head = try session.rollback(layer: .machine, to: 1, expected: binding(preview))

        #expect(head.revision == 3)
        #expect(try session.loadMachineDocument().rules == [previewDeny])
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

/// Every entry under `root` (and `root` itself): type, POSIX mode, and
/// bytes for files. A preview must change none of it, including creating
/// a lock file or chmodding a directory.
private struct EntrySnapshot: Equatable {
    var type: FileAttributeType
    var mode: Int
    var bytes: Data?
}

private func directorySnapshot(_ root: URL) throws -> [String: EntrySnapshot] {
    var snapshot: [String: EntrySnapshot] = [:]
    func record(_ path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let type = attributes[.type] as? FileAttributeType ?? .typeUnknown
        snapshot[path] = EntrySnapshot(
            type: type,
            mode: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1,
            bytes: type == .typeRegular ? try Data(contentsOf: URL(fileURLWithPath: path)) : nil
        )
    }
    try record(root.path)
    for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
        try record(root.appendingPathComponent(relative).path)
    }
    return snapshot
}

private func isolatedPreviewDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-rollback-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func binding(_ preview: PolicyWorkspace.RollbackPreview) -> PolicyRollbackBinding {
    PolicyRollbackBinding(target: preview.target, head: preview.head)
}

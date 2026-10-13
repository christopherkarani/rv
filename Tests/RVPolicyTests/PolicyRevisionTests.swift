import Foundation
import Testing
import RVDomain
import RVPolicy

@Suite("PolicyRevision")
struct PolicyRevisionTests {
    @Test func machineSavesAppendMonotonicRevisions() throws {
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)

        try store.saveMachine([forcePushMainDeny()])
        try store.saveMachine([forcePushMainDeny(), discardAsk()])

        let entries = try store.listMachineRevisions()
        #expect(entries.count == 2)
        #expect(entries.map(\.revision) == [1, 2])
        #expect(entries[0].hash != entries[1].hash)
        #expect(entries.map(\.ruleCount) == [1, 2])
        #expect(entries[0].schemaVersion == PolicyRevision.currentSchemaVersion)
        let lines = try String(contentsOf: store.machineRevisionsURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)
    }

    @Test func identicalSaveKeepsHeadWithoutNewRevision() throws {
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let rules = [forcePushMainDeny()]

        try store.saveMachine(rules)
        try store.saveMachine(rules)

        let entries = try store.listMachineRevisions()
        #expect(entries.count == 1)
        #expect(entries[0].revision == 1)
    }

    @Test func rollbackResubmitsEarlierRevisionAsNewHead() throws {
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let first = [forcePushMainDeny()]
        let second = [discardAsk()]

        try store.saveMachine(first)
        try store.saveMachine(second)
        let before = try Data(contentsOf: store.machineRevisionsURL)

        let head = try store.rollbackMachine(to: 1)

        #expect(head.revision == 3)
        #expect(try store.loadMachine() == first)
        let entries = try store.listMachineRevisions()
        #expect(entries.map(\.revision) == [1, 2, 3])
        #expect(entries[2].hash == entries[0].hash)
        #expect(entries[2].toml == entries[0].toml)
        let after = try Data(contentsOf: store.machineRevisionsURL)
        #expect(after.count > before.count)
        #expect(after.prefix(before.count) == before)
    }

    @Test func rollbackUnknownRevisionThrows() throws {
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        #expect(throws: TypedRuleStoreError.unknownRevision) {
            _ = try store.rollbackMachine(to: 99)
        }
        #expect(throws: TypedRuleStoreError.unknownRevision) {
            _ = try store.rollbackRepo(to: 1, workspace: root)
        }
    }

    @Test func canonicalHashIgnoresRuleOrderAndEnglish() {
        let deny = PolicyDocumentRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            verdict: .deny,
            predicate: .gitPush(force: .exactly(.force), branch: "main")
        )
        let ask = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "discard"),
            verdict: .ask,
            predicate: .gitDiscardWorktree(pathspec: nil),
            english: "Ask before discarding"
        )
        let forward = PolicyDocument(rules: [deny, ask])
        let reversed = PolicyDocument(rules: [ask, deny])
        #expect(PolicyRevisionIdentity.hash(forward) == PolicyRevisionIdentity.hash(reversed))

        let withoutEnglish = PolicyDocument(
            rules: [
                deny,
                PolicyDocumentRule(
                    id: ask.id,
                    verdict: ask.verdict,
                    predicate: ask.predicate
                ),
            ]
        )
        #expect(PolicyRevisionIdentity.hash(forward) == PolicyRevisionIdentity.hash(withoutEnglish))

        let weakened = PolicyDocument(
            rules: [
                PolicyDocumentRule(
                    id: deny.id,
                    verdict: .allow,
                    predicate: deny.predicate
                ),
                ask,
            ]
        )
        #expect(PolicyRevisionIdentity.hash(forward) != PolicyRevisionIdentity.hash(weakened))
    }

    @Test func repoRevisionsAreSeparateFromMachine() throws {
        let config = try isolatedRevisionDirectory()
        let workspace = try isolatedRevisionDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)

        try store.saveMachine([forcePushMainDeny()])
        try store.saveRepo([discardAsk()], workspace: workspace)
        try store.saveRepo([discardAsk(), forcePushMainAllow()], workspace: workspace)

        #expect(try store.listMachineRevisions().map(\.revision) == [1])
        let repo = try store.listRepoRevisions(workspace: workspace)
        #expect(repo.map(\.revision) == [1, 2])
        #expect(repo.map(\.ruleCount) == [1, 2])
    }

    @Test func missingLogListsEmptyWithoutMinting() throws {
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("absent", isDirectory: true)
        let store = TypedRuleStore(baseDirectory: missing)
        #expect(try store.listMachineRevisions() == [])
        #expect(FileManager.default.fileExists(atPath: missing.path) == false)
        #expect(try store.listRepoRevisions(workspace: missing) == [])
    }

    @Test func corruptLogFailsClosed() throws {
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        let handle = try FileHandle(forWritingTo: store.machineRevisionsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.listMachineRevisions()
        }
    }

    @Test func saveWithCorruptLogLeavesDocumentUntouched() throws {
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        let before = try Data(contentsOf: store.machineFileURL)

        let handle = try FileHandle(forWritingTo: store.machineRevisionsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        #expect(throws: TypedRuleStoreError.invalidFile) {
            try store.saveMachine([forcePushMainDeny(), discardAsk()])
        }
        // The rejected save must not move the document: no history gap.
        #expect(try Data(contentsOf: store.machineFileURL) == before)
        #expect(try store.loadMachine() == [forcePushMainDeny()])
    }

    @Test func forgedLogLinesFailClosed() throws {
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        try store.saveMachine([forcePushMainDeny(), discardAsk()])
        let lines = try String(contentsOf: store.machineRevisionsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        // Tampered TOML under the original hash.
        var tampered = try decoder.decode(PolicyRevision.self, from: Data(lines[1].utf8))
        tampered.toml = tampered.toml.replacingOccurrences(of: "deny", with: "allow")
        #expect(tampered.toml != (try decoder.decode(PolicyRevision.self, from: Data(lines[1].utf8)).toml))
        try (lines[0] + "\n" + String(decoding: encoder.encode(tampered), as: UTF8.self) + "\n")
            .write(to: store.machineRevisionsURL, atomically: true, encoding: .utf8)
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.listMachineRevisions()
        }

        // Renumbered revision breaks the gapless sequence.
        var renumbered = try decoder.decode(PolicyRevision.self, from: Data(lines[1].utf8))
        renumbered.revision = 7
        try (lines[0] + "\n" + String(decoding: encoder.encode(renumbered), as: UTF8.self) + "\n")
            .write(to: store.machineRevisionsURL, atomically: true, encoding: .utf8)
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.listMachineRevisions()
        }

        // Reordered lines break line/sequence agreement.
        try (lines[1] + "\n" + lines[0] + "\n")
            .write(to: store.machineRevisionsURL, atomically: true, encoding: .utf8)
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.listMachineRevisions()
        }
    }

    @Test func restrictOnlyAndStrictWinsHoldAfterRollback() throws {
        let config = try isolatedRevisionDirectory()
        let workspace = try isolatedRevisionDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        let machineDeny = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            predicate: predicate,
            verdict: .deny,
            origin: .machine
        )
        let repoAllow = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main-allow"),
            predicate: predicate,
            verdict: .allow,
            origin: .repo
        )
        try store.saveMachine(
            PolicyDocument(
                rules: [
                    PolicyDocumentRule(
                        id: machineDeny.id,
                        verdict: .deny,
                        predicate: predicate
                    ),
                ],
                safetyLevel: .strict
            )
        )
        try store.saveRepo([repoAllow], workspace: workspace)
        try store.saveMachine(PolicyDocument(rules: [], safetyLevel: .normal))
        _ = try store.rollbackMachine(to: 1)

        let effective = try store.loadEffective(builtin: [], workspace: workspace)
        #expect(effective == [machineDeny])
        #expect(try store.loadMachineDocument().safetyLevel == .strict)
    }

    @Test func workspaceListsAndRollsBackBothLayers() throws {
        let config = try isolatedRevisionDirectory()
        let workspace = try isolatedRevisionDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let session = PolicyWorkspace(configDirectory: config, workspace: workspace)
        let deny = PolicyDocumentRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            verdict: .deny,
            predicate: .gitPush(force: .exactly(.force), branch: "main")
        )
        try session.upsert(deny, layer: .machine)
        try session.upsert(deny, layer: .repo)

        #expect(try session.listRevisions(layer: .machine).count == 1)
        #expect(try session.listRevisions(layer: .repo).count == 1)

        try session.upsert(
            PolicyDocumentRule(
                id: RuleID(pack: .typedGit, pattern: "discard"),
                verdict: .ask,
                predicate: .gitDiscardWorktree(pathspec: nil)
            ),
            layer: .machine
        )
        let head = try session.rollback(layer: .machine, to: 1)
        #expect(head.revision == 3)
        #expect(try session.loadMachineDocument().rules == [deny])
        #expect(try session.listRevisions(layer: .machine).count == 3)
    }

    @Test func repoRevisionOpsRefuseWithoutMachineDirectory() throws {
        // The repo revision log must live in the machine config dir, not
        // inside the workspace a caged writer controls. With no machine
        // directory, revision operations refuse instead of falling back
        // to a workspace-local (forgeable) log; document reads still work.
        let workspace = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let session = PolicyWorkspace(home: nil, workspace: workspace)
        #expect(throws: PolicyWorkspaceError.missingLayer(.machine)) {
            _ = try session.listRevisions(layer: .repo)
        }
        #expect(throws: PolicyWorkspaceError.missingLayer(.machine)) {
            _ = try session.rollback(layer: .repo, to: 1)
        }
        #expect(try session.loadRepoDocument() == PolicyDocument())
    }

    @Test func workspaceRevisionReadsWithoutLayerThrow() {
        let session = PolicyWorkspace(home: nil, workspace: nil)
        #expect(throws: PolicyWorkspaceError.missingLayer(.machine)) {
            _ = try session.listRevisions(layer: .machine)
        }
        #expect(throws: PolicyWorkspaceError.missingLayer(.repo)) {
            _ = try session.listRevisions(layer: .repo)
        }
        #expect(throws: PolicyWorkspaceError.missingLayer(.machine)) {
            _ = try session.rollback(layer: .machine, to: 1)
        }
        #expect(throws: PolicyWorkspaceError.missingLayer(.repo)) {
            _ = try session.rollback(layer: .repo, to: 1)
        }
    }

    @Test func machineListRejectsRecomputedForgery() throws {
        // BYPASS-1 (2026-10-10): a fully self-consistent forgery (parseable
        // TOML, recomputed plain hash, gapless numbering) must still refuse:
        // the .jsonl CLI history is cross-checked against the sealed HMAC log.
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        try store.saveMachine([forcePushMainDeny(), discardAsk()])

        let forgedDoc = PolicyDocument(rules: [
            PolicyDocumentRule(
                id: RuleID(pack: .coreGit, pattern: "forged-allow"),
                verdict: .allow,
                predicate: .gitPush(force: .exactly(.force), branch: "main")
            ),
        ])
        let forgedTOML = PolicyDocumentTOML.render(forgedDoc)
        let forged = PolicyRevision(
            revision: 2,
            hash: PolicyRevisionIdentity.hash(forgedDoc),
            ruleCount: forgedDoc.rules.count,
            recordedAt: Date(),
            toml: forgedTOML,
            document: forgedDoc
        )
        let lines = try String(contentsOf: store.machineRevisionsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
        let forgedLine = String(decoding: try JSONEncoder().encode(forged), as: UTF8.self)
        try (lines[0] + "\n" + forgedLine + "\n")
            .write(to: store.machineRevisionsURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: store.machineFileURL)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            _ = try store.listMachineRevisions()
        }
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            _ = try store.rollbackMachine(to: 2)
        }
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.saveMachine([discardAsk()])
        }
        #expect(try store.loadMachine() == [forcePushMainDeny(), discardAsk()])
        #expect(try Data(contentsOf: store.machineFileURL) == before)
    }

    @Test func machineSaveRefusesAfterJsonlDelete() throws {
        // BYPASS-2 (2026-10-10): deleting the .jsonl CLI history must fail
        // closed (logMissing), never silently re-mint r1 over sealed history.
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        let before = try Data(contentsOf: store.machineFileURL)

        try FileManager.default.removeItem(at: store.machineRevisionsURL)

        #expect(throws: TypedRuleStoreError.logMissing) {
            _ = try store.listMachineRevisions()
        }
        #expect(throws: TypedRuleStoreError.logMissing) {
            try store.saveMachine([forcePushMainDeny(), discardAsk()])
        }
        #expect(FileManager.default.fileExists(atPath: store.machineRevisionsURL.path) == false)
        #expect(try Data(contentsOf: store.machineFileURL) == before)
    }

    @Test func machineRollbackRefusesTruncatedHistory() throws {
        // A truncated .jsonl must not move the relax-gate baseline or mint
        // colliding revisions: rollback refuses when the sealed tail is not
        // a duplicate extension of the display list.
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let weak = PolicyDocument(rules: [
            PolicyDocumentRule(
                id: RuleID(pack: .coreGit, pattern: "force-push-main"),
                verdict: .allow,
                predicate: .gitPush(force: .exactly(.force), branch: "main")
            ),
        ])
        let strict = PolicyDocument(rules: [
            PolicyDocumentRule(
                id: RuleID(pack: .coreGit, pattern: "force-push-main"),
                verdict: .deny,
                predicate: .gitPush(force: .exactly(.force), branch: "main")
            ),
        ])
        try store.saveMachine(weak)
        try store.saveMachine(strict)
        let before = try Data(contentsOf: store.machineFileURL)
        let lines = try String(contentsOf: store.machineRevisionsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
        try (lines[0] + "\n")
            .write(to: store.machineRevisionsURL, atomically: true, encoding: .utf8)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            _ = try store.rollbackMachine(to: 1)
        }
        #expect(try Data(contentsOf: store.machineFileURL) == before)
    }

    @Test func reinitializeReconcilesJsonlToDiskState() throws {
        // Operator recovery re-mints BOTH logs from disk state so later
        // reads agree; unverified past lines are dropped, never laundered.
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        try store.saveMachine([forcePushMainDeny(), discardAsk()])

        try FileManager.default.removeItem(at: RVPolicyPaths.policyRevisionLogFile(inConfigDir: root))
        try FileManager.default.removeItem(at: RVPolicyPaths.policyRevisionLogTipFile(inConfigDir: root))
        try FileManager.default.removeItem(at: RVPolicyPaths.policyRevisionLogKeyFile(inConfigDir: root))

        try store.reinitializeMachineLog()
        let entries = try store.listMachineRevisions()
        #expect(entries.map(\.revision) == [1])
        #expect(try store.machineHistory().map(\.revision) == [1])
        #expect(try store.loadMachine() == [forcePushMainDeny(), discardAsk()])

        try store.saveMachine([forcePushMainDeny()])
        #expect(try store.listMachineRevisions().map(\.revision) == [1, 2])
    }

    @Test func rollbackToRevisionKeepsDisplayReadsWorking() throws {
        // Review fixup (2026-10-10): the verified rollback path must
        // dual-write the display log too, or every later cross-checked
        // read bricks until operator recovery.
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let first = PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")])
        let second = PolicyDocument(rules: [denyRule(pattern: "v2", branch: "develop")])
        try store.saveMachine(first)
        try store.saveMachine(second)

        let head = try store.rollbackMachine(toRevision: 1)
        #expect(head.revision == 3)
        #expect(head.document == first)

        #expect(try store.listMachineRevisions().map(\.revision) == [1, 2, 3])
        let third = PolicyDocument(rules: [denyRule(pattern: "v3", branch: "release")])
        try store.saveMachine(third)
        #expect(try store.listMachineRevisions().map(\.revision) == [1, 2, 3, 4])
        // Rollback to the current head re-saves identical bytes: no new
        // .jsonl generation (identical-save no-op), HMAC seals a duplicate
        // tail — and every read still agrees afterwards.
        let again = try store.rollbackMachine(to: 4)
        #expect(again.revision == 4)
        #expect(try store.listMachineRevisions().map(\.revision) == [1, 2, 3, 4])
        // One public numbering: history reports generations, so the
        // duplicate sealed tail record does not mint a revision 5.
        #expect(try store.machineHistory().map(\.revision) == [1, 2, 3, 4])
    }

    @Test func identicalResaveThenDistinctSaveKeepsReadsWorking() throws {
        // Numbering-divergence guard (2026-10-10): identical re-saves seal
        // without a .jsonl line, so sealed numbering runs ahead; a later
        // distinct save must still leave every read working.
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let first = PolicyDocument(rules: [denyRule(pattern: "v1", branch: "main")])
        let second = PolicyDocument(rules: [denyRule(pattern: "v2", branch: "develop")])
        try store.saveMachine(first)
        try store.saveMachine(first)
        try store.saveMachine(second)

        #expect(try store.listMachineRevisions().map(\.revision) == [1, 2])
        // One public numbering: the identical re-save sealed an internal
        // duplicate but minted no generation, so history agrees with list.
        #expect(try store.machineHistory().map(\.revision) == [1, 2])
        let head = try store.rollbackMachine(to: 1)
        #expect(head.revision == 3)
        #expect(try store.listMachineRevisions().map(\.revision) == [1, 2, 3])
    }

    @Test func machineListRejectsForgedRuleCount() throws {
        // Metadata forgery (2026-10-10 re-review): a line with intact TOML
        // and hash but an edited `rule_count` must refuse. The count is
        // recounted from the line's own TOML on every read.
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        try store.saveMachine([forcePushMainDeny(), discardAsk()])

        let lines = try String(contentsOf: store.machineRevisionsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
        var forged = try JSONDecoder().decode(
            PolicyRevision.self, from: Data(lines[1].utf8)
        )
        forged.ruleCount += 1
        let forgedLine = String(decoding: try JSONEncoder().encode(forged), as: UTF8.self)
        try (lines[0] + "\n" + forgedLine + "\n")
            .write(to: store.machineRevisionsURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: store.machineFileURL)

        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.listMachineRevisions()
        }
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.rollbackMachine(to: 2)
        }
        #expect(throws: TypedRuleStoreError.invalidFile) {
            try store.saveMachine([discardAsk()])
        }
        #expect(try Data(contentsOf: store.machineFileURL) == before)
    }

    @Test func machineListRejectsForgedRecordedAt() throws {
        // Metadata forgery (2026-10-10 re-review): a line with intact TOML,
        // hash, and rule count but an edited `recorded_at` must refuse.
        // The display timestamp must match the sealed record's MAC'd time.
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        try store.saveMachine([forcePushMainDeny(), discardAsk()])

        let lines = try String(contentsOf: store.machineRevisionsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
        var forged = try JSONDecoder().decode(
            PolicyRevision.self, from: Data(lines[1].utf8)
        )
        forged.recordedAt = forged.recordedAt.addingTimeInterval(3600)
        let forgedLine = String(decoding: try JSONEncoder().encode(forged), as: UTF8.self)
        try (lines[0] + "\n" + forgedLine + "\n")
            .write(to: store.machineRevisionsURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: store.machineFileURL)

        #expect(throws: TypedRuleStoreError.logCorrupted) {
            _ = try store.listMachineRevisions()
        }
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            _ = try store.rollbackMachine(to: 2)
        }
        #expect(throws: TypedRuleStoreError.logCorrupted) {
            try store.saveMachine([discardAsk()])
        }
        #expect(try Data(contentsOf: store.machineFileURL) == before)
    }

    @Test func machineHistorySurfacesSealedTime() throws {
        // History timestamps are the sealed record times: stable across
        // reads and identical to the display log's, never read time.
        let root = try isolatedRevisionDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try store.saveMachine([forcePushMainDeny()])
        try store.saveMachine([forcePushMainDeny(), discardAsk()])

        let history = try store.machineHistory()
        let listed = try store.listMachineRevisions()
        #expect(history.map(\.recordedAt) == listed.map(\.recordedAt))
        #expect(try store.machineHistory().map(\.recordedAt) == history.map(\.recordedAt))
    }

    @Test func repoListRejectsForgedRuleCount() throws {
        // The repo layer has no sealed log, but `rule_count` is still
        // recounted from the line's own TOML: an edited count refuses.
        // (Repo `recorded_at` stays unverified display — documented
        // residual: same-uid forge on the repo layer is accepted.)
        let config = try isolatedRevisionDirectory()
        let workspace = try isolatedRevisionDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        try store.saveRepo([discardAsk()], workspace: workspace)
        try store.saveRepo([discardAsk(), forcePushMainAllow()], workspace: workspace)

        let revisionsURL = store.repoRevisionsURL(workspace: workspace)
        let lines = try String(contentsOf: revisionsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
        var forged = try JSONDecoder().decode(
            PolicyRevision.self, from: Data(lines[1].utf8)
        )
        forged.ruleCount += 1
        let forgedLine = String(decoding: try JSONEncoder().encode(forged), as: UTF8.self)
        try (lines[0] + "\n" + forgedLine + "\n")
            .write(to: revisionsURL, atomically: true, encoding: .utf8)

        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.listRepoRevisions(workspace: workspace)
        }
    }
}

private func forcePushMainDeny() -> TypedRule {
    TypedRule(
        id: RuleID(pack: .coreGit, pattern: "force-push-main"),
        predicate: .gitPush(force: .exactly(.force), branch: "main"),
        verdict: .deny,
        origin: .machine
    )
}

private func forcePushMainAllow() -> TypedRule {
    TypedRule(
        id: RuleID(pack: .coreGit, pattern: "force-push-main-allow"),
        predicate: .gitPush(force: .exactly(.force), branch: "main"),
        verdict: .allow,
        origin: .repo
    )
}

private func discardAsk() -> TypedRule {
    TypedRule(
        id: RuleID(pack: .typedGit, pattern: "discard"),
        predicate: .gitDiscardWorktree(pathspec: nil),
        verdict: .ask,
        origin: .machine
    )
}

private func isolatedRevisionDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-policy-rev-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

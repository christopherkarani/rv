import Foundation
import Testing
import RVDomain
@testable import RVPolicy

@Suite("RulePinStore")
struct RulePinStoreTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func saveAlwaysBlock_forcePushMain_loadsAsMachineTypedDeny() throws {
        let root = try isolatedPinStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = forcePushWait(id: "shared", branch: "main")
        let draft = RulePinning.draft(record: record, polarity: .block)

        let outcome = try RulePinStore(baseDirectory: root).save(
            record: record,
            polarity: .block,
            draft: draft,
            now: now
        )

        let store = TypedRuleStore(baseDirectory: root)
        let loaded = try store.loadMachine()
        let rule = try #require(loaded.first)
        #expect(loaded.count == 1)
        #expect(rule.id == outcome.ruleID)
        #expect(rule.predicate == .gitPush(force: .force, branch: "main"))
        #expect(rule.verdict == .deny)
        #expect(rule.origin == .machine)
        let json = try String(contentsOf: store.machineFileURL, encoding: .utf8)
        #expect(json.contains("supportingCommand") == false)
        #expect(json.contains("git push") == false)
        #expect(json.contains("english") == false)
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        #expect(snap.blocked.entries.isEmpty)
    }

    @Test func saveAlwaysAllow_forcePushMain_throwsHardStopAndWritesNothing() throws {
        let root = try isolatedPinStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = forcePushWait(id: "shared", branch: "main")
        let draft = RulePinning.draft(record: record, polarity: .allow)
        let pin = RulePinStore(baseDirectory: root)
        #expect(throws: RulePinError.hardStop) {
            try pin.save(record: record, polarity: .allow, draft: draft, now: now)
        }
        #expect(try TypedRuleStore(baseDirectory: root).loadMachine().isEmpty)
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        #expect(snap.blocked.entries.isEmpty)
    }

    @Test func saveWrongDraft_forcePushMain_throwsDraftMismatchAndWritesNothing() throws {
        let root = try isolatedPinStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = forcePushWait(id: "shared", branch: "main")
        #expect(throws: RulePinError.draftMismatch) {
            try RulePinStore(baseDirectory: root).save(
                record: record,
                polarity: .block,
                draft: "forged",
                now: now
            )
        }
        #expect(try TypedRuleStore(baseDirectory: root).loadMachine().isEmpty)
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        #expect(snap.blocked.entries.isEmpty)
    }

    @Test func saveAlwaysAllow_featureForcePush_writesMachineTypedAllow() throws {
        let root = try isolatedPinStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = forcePushWait(id: "feature", branch: "feature")
        let draft = RulePinning.draft(record: record, polarity: .allow)

        let outcome = try RulePinStore(baseDirectory: root).save(
            record: record,
            polarity: .allow,
            draft: draft,
            now: now
        )

        let loaded = try TypedRuleStore(baseDirectory: root).loadMachine()
        let rule = try #require(loaded.first)
        #expect(loaded.count == 1)
        #expect(rule.id == outcome.ruleID)
        #expect(rule.predicate == .gitPush(force: .force, branch: "feature"))
        #expect(rule.verdict == .allow)
        #expect(rule.origin == .machine)
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        #expect(snap.blocked.entries.isEmpty)
    }

    @Test func saveAlwaysAllow_nonGit_stillPinsExactCommand() throws {
        let root = try isolatedPinStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = resetHardWait()
        let draft = RulePinning.draft(record: record, polarity: .allow)
        _ = try RulePinStore(baseDirectory: root).save(
            record: record,
            polarity: .allow,
            draft: draft,
            now: now
        )
        #expect(try TypedRuleStore(baseDirectory: root).loadMachine().isEmpty)
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.matches(ruleID: nil, matchingView: "git reset --hard", now: now))
    }
}

private func resetHardWait() -> PendingApproval {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return PendingApproval(
        id: ApprovalID(rawValue: "pin-ok"),
        identity: ApprovalIdentity(
            session: SessionIdentity(rawValue: "sess"),
            agent: AgentIdentity(rawValue: "pi")
        ),
        action: .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "fp-pin-ok"),
                effects: ActionEffects(kinds: []),
                resources: ActionResources(),
                scope: ActionScope(workingDirectory: wd("/tmp/ws")),
                supportingCommand: ShellCommand(rawValue: "git reset --hard")
            )
        ),
        reason: .hostAsk,
        continuation: .hostNative,
        timeoutPolicy: .keepWaiting,
        createdAt: now,
        expiresAt: now.addingTimeInterval(3600),
        state: .awaitingHuman
    )
}

private func forcePushWait(id: String, branch: String) -> PendingApproval {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return PendingApproval(
        id: ApprovalID(rawValue: id),
        identity: ApprovalIdentity(
            session: SessionIdentity(rawValue: "sess"),
            agent: AgentIdentity(rawValue: "pi")
        ),
        action: .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "fp-\(id)"),
                effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                resources: ActionResources(
                    remoteName: "origin",
                    branchName: branch
                ),
                scope: ActionScope(workingDirectory: wd("/tmp/ws")),
                supportingCommand: ShellCommand(rawValue: "git push --force origin \(branch)")
            )
        ),
        reason: .hostAsk,
        continuation: .hostNative,
        timeoutPolicy: .keepWaiting,
        createdAt: now,
        expiresAt: now.addingTimeInterval(3600),
        state: .awaitingHuman
    )
}

private func isolatedPinStoreDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-rule-pin-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct RulePinningTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test(arguments: [
        RuleHardStopKind.secretPath,
        .protectedSharedBranch,
        .workingTreeDiscard,
        .outsideRepository,
        .unresolvedPath,
    ])
    func alwaysAllowPreview_hardStopForbidsSave(kind: RuleHardStopKind) {
        let preview = RulePinning.preview(record: wait(kind: kind), polarity: .allow)
        #expect(preview.allowedToSave == false)
        #expect(preview.draft.isEmpty == false)
        #expect(preview.sentence.contains("hard stop"))
        #expect(RulePinning.hardStop(in: wait(kind: kind).action) == kind)
    }

    @Test func alwaysAllowPreview_pinOkMaySave() {
        let preview = RulePinning.preview(record: pinOkWait(), polarity: .allow)
        #expect(preview.allowedToSave == true)
        #expect(preview.sentence.contains("Always allow"))
        #expect(preview.sentence.contains("git reset") == false)
    }

    @Test func alwaysBlockPreview_hardStopMaySave() {
        let preview = RulePinning.preview(
            record: wait(kind: .protectedSharedBranch),
            polarity: .block
        )
        #expect(preview.allowedToSave == true)
        #expect(preview.sentence.contains("Always block"))
    }

    @Test func draftBindsIdPolarityAndFingerprint() {
        let record = pinOkWait()
        let allow = RulePinning.draft(record: record, polarity: .allow)
        let block = RulePinning.draft(record: record, polarity: .block)
        #expect(allow != block)
        var other = record
        other.id = ApprovalID(rawValue: "other-id")
        #expect(RulePinning.draft(record: other, polarity: .allow) != allow)
    }

    @Test func previewDoesNotWriteAllowlistOrDenylist() throws {
        let root = try isolatedPinDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = RulePinning.preview(record: pinOkWait(), polarity: .allow)
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        #expect(snap.blocked.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: RVPolicyPaths.allowlistFile(inConfigDir: root).path) == false)
    }

    @Test func saveAlwaysAllowHardStopWritesNothing() throws {
        let root = try isolatedPinDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = wait(kind: .secretPath)
        let draft = RulePinning.draft(record: record, polarity: .allow)
        let store = RulePinStore(baseDirectory: root)
        #expect(throws: RulePinError.hardStop) {
            try store.save(record: record, polarity: .allow, draft: draft, now: now)
        }
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        #expect(snap.blocked.entries.isEmpty)
    }

    @Test func saveWrongDraftDoesNotWrite() throws {
        let root = try isolatedPinDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = pinOkWait()
        #expect(throws: RulePinError.draftMismatch) {
            try RulePinStore(baseDirectory: root).save(
                record: record,
                polarity: .allow,
                draft: "forged",
                now: now
            )
        }
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
    }

    @Test func saveWithoutMatchingViewWritesNothing() throws {
        let root = try isolatedPinDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = wait(
            id: "empty",
            command: "   ",
            effects: [],
            branchName: nil
        )
        let draft = RulePinning.draft(record: record, polarity: .allow)
        #expect(throws: RulePinError.missingMatchingView) {
            try RulePinStore(baseDirectory: root).save(
                record: record,
                polarity: .allow,
                draft: draft,
                now: now
            )
        }
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        #expect(snap.blocked.entries.isEmpty)
    }

    @Test func savePinsCallerMatchingView() throws {
        let root = try isolatedPinDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = wait(
            id: "wrap",
            command: "sudo git reset --hard",
            effects: [],
            branchName: nil
        )
        let draft = RulePinning.draft(record: record, polarity: .allow)
        _ = try RulePinStore(baseDirectory: root).save(
            record: record,
            polarity: .allow,
            draft: draft,
            now: now,
            matchingView: MatchingView("git reset --hard")
        )
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.matches(ruleID: nil, matchingView: "git reset --hard", now: now))
        #expect(snap.matches(ruleID: nil, matchingView: "sudo git reset --hard", now: now) == false)
    }

    @Test func saveAlwaysAllowPinsExactCommandIdempotently() throws {
        let root = try isolatedPinDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = pinOkWait()
        let draft = RulePinning.draft(record: record, polarity: .allow)
        let store = RulePinStore(baseDirectory: root)
        let first = try store.save(record: record, polarity: .allow, draft: draft, now: now)
        let second = try store.save(record: record, polarity: .allow, draft: draft, now: now)
        #expect(first.ruleID == second.ruleID)
        #expect(first.ruleID.pack.rawValue == "pin.allow")
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.count == 1)
        #expect(snap.matches(ruleID: nil, matchingView: "git reset --hard", now: now))
        let denied = resetHardDeny()
        let gated = PolicyGate.decide(
            denied,
            cwd: wd("/tmp/ws"),
            allowlist: snap,
            grant: .none,
            now: now
        )
        #expect(gated.override == .allowlist)
        #expect(gated.result.decision == .allow)
    }

    @Test func saveAlwaysBlockPinsAndBeatsAllowlist() throws {
        let root = try isolatedPinDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = pinOkWait()
        let draft = RulePinning.draft(record: record, polarity: .block)
        _ = try RulePinStore(baseDirectory: root).save(
            record: record,
            polarity: .block,
            draft: draft,
            now: now
        )
        try AllowlistStore(baseDirectory: root).pin(
            AllowlistEntry(
                selector: .exactCommand("git reset --hard"),
                reason: "later allow",
                addedAt: now
            )
        )
        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.blocked.matches("git reset --hard"))
        #expect(snap.matches(ruleID: nil, matchingView: "git reset --hard", now: now) == false)
        let gated = PolicyGate.decide(
            resetHardDeny(),
            cwd: wd("/tmp/ws"),
            allowlist: snap,
            grant: .none,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("Always-block must keep the deny")
            return
        }
    }

    @Test func policyGateDoesNotHonorAllowlistOnSecretDeny() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deny = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreSecrets, pattern: "env"),
                    reason: "Access to a sensitive path is not allowed."
                ),
                matched: nil
            ),
            matchingView: "cat .env"
        )
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .exactCommand("cat .env"), reason: "nope", addedAt: now),
        ])
        let gated = PolicyGate.decide(
            deny,
            cwd: wd("/tmp/ws"),
            allowlist: allowlist,
            grant: .none,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("secret-path deny must stay a hard stop")
            return
        }
    }

    private func pinOkWait() -> PendingApproval {
        wait(
            id: "pin-ok",
            command: "git reset --hard",
            effects: [],
            branchName: nil
        )
    }

    private func wait(kind: RuleHardStopKind) -> PendingApproval {
        switch kind {
        case .secretPath:
            return wait(
                id: "secret",
                command: "cat .env",
                effects: [],
                branchName: nil
            )
        case .protectedSharedBranch:
            return wait(
                id: "shared",
                command: "git push --force origin main",
                effects: [.remoteSharedBranchMutation],
                branchName: "main"
            )
        case .workingTreeDiscard:
            return wait(
                id: "discard",
                command: "git checkout -- .",
                effects: [.workingTreeDiscard],
                branchName: nil
            )
        case .outsideRepository:
            return wait(
                id: "outside",
                command: "rm ../outside-file",
                effects: [.filesystemDelete, .outsideRepositoryMutation],
                branchName: nil,
                path: "/tmp/outside-file",
                scope: .outsideRepository
            )
        case .unresolvedPath:
            return wait(
                id: "unresolved",
                command: "rm gone",
                effects: [.filesystemDelete, .unresolvedFilesystem],
                branchName: nil,
                path: "/gone/file",
                scope: .unknown
            )
        }
    }

    private func wait(
        id: String,
        command: String,
        effects: [ActionEffectKind],
        branchName: String?,
        path: String? = nil,
        scope: FilesystemScope? = nil
    ) -> PendingApproval {
        PendingApproval(
            id: ApprovalID(rawValue: id),
            identity: ApprovalIdentity(
                session: SessionIdentity(rawValue: "sess"),
                agent: AgentIdentity(rawValue: "pi")
            ),
            action: .shell(
                ShellAction(
                    fingerprint: ActionFingerprint(rawValue: "fp-\(id)"),
                    effects: ActionEffects(kinds: effects),
                    resources: ActionResources(
                        remoteName: "origin",
                        branchName: branchName,
                        path: path,
                        filesystemScope: scope
                    ),
                    scope: ActionScope(workingDirectory: wd("/tmp/ws")),
                    supportingCommand: ShellCommand(rawValue: command)
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
}

private func resetHardDeny() -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                reason: "git reset --hard destroys uncommitted changes"
            ),
            matched: nil
        ),
        matchingView: "git reset --hard"
    )
}

private func isolatedPinDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-rule-pin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

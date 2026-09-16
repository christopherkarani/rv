import Foundation
import Testing
import RVDomain

@Suite("ProposedAction.file")
struct ProposedActionFileTests {
    private let secretPath = "/tmp/ghp_exampletoken/.env"
    private let file = FileToolAction(
        kind: .read,
        path: FileToolPath(rawValue: "/tmp/ghp_exampletoken/.env")
    )

    @Test func actionFingerprint_makeFile_usesFileSpellingAndEmptySlots() throws {
        let session = try #require(SessionID(validating: "sess_1"))
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let withSlots = ActionFingerprint.make(
            host: .claude,
            session: session,
            cwd: cwd,
            file: file
        )
        #expect(withSlots.rawValue == "file:claude:sess_1:/tmp/ws:read:/tmp/ghp_exampletoken/.env")

        let emptySlots = ActionFingerprint.make(
            host: .cursor,
            session: nil,
            cwd: nil,
            file: FileToolAction(kind: .write, path: FileToolPath(rawValue: "/tmp/notes.md"))
        )
        #expect(emptySlots.rawValue == "file:cursor:::write:/tmp/notes.md")
    }

    @Test func actionFingerprint_makeFile_doesNotCollideWithShellPathCommand() throws {
        let session = try #require(SessionID(validating: "abc-123"))
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let asFile = ActionFingerprint.make(
            host: .grok,
            session: session,
            cwd: cwd,
            file: file
        )
        let asShell = ActionFingerprint.make(
            host: .grok,
            session: session,
            cwd: cwd,
            command: ShellCommand(rawValue: file.path.rawValue)
        )
        #expect(asFile != asShell)
        #expect(asFile.rawValue.hasPrefix("file:"))
        #expect(asShell.rawValue.hasPrefix("file:") == false)
    }

    @Test func reviewSanitizer_fileAction_redactsSecretShapedPathAndReturnsFile() {
        let dirty = ProposedAction.file(
            FileAction(
                fingerprint: ActionFingerprint(
                    rawValue: "file:claude:sess:/tmp/ws:read:\(secretPath)"
                ),
                file: file,
                effects: ActionEffects(),
                resources: ActionResources(path: secretPath),
                scope: ActionScope()
            )
        )
        let sanitized = ReviewSanitizer.sanitize(dirty)
        guard case .file(let cleaned) = sanitized else {
            Issue.record("expected ProposedAction.file after sanitize")
            return
        }
        #expect(cleaned.file.path.rawValue.contains("ghp_exampletoken") == false)
        #expect(cleaned.resources.path?.contains("ghp_exampletoken") == false)
        #expect(cleaned.fingerprint.rawValue.contains("ghp_exampletoken") == false)
        #expect(cleaned.file.path.rawValue.contains(ReviewSanitizer.redactedPlaceholder))
        #expect(cleaned.resources.path == ReviewSanitizer.redactedPlaceholder)
        #expect(sanitized.supportingCommand == nil)
    }

    @Test func actionPolicyEngine_emptyEffectsFile_doesNotEmitGitBuiltinDenials() {
        let action = ProposedAction.file(
            FileAction(
                fingerprint: ActionFingerprint(rawValue: "file:claude:::read:/tmp/notes.md"),
                file: FileToolAction(
                    kind: .read,
                    path: FileToolPath(rawValue: "/tmp/notes.md")
                ),
                effects: ActionEffects(),
                resources: ActionResources(path: "/tmp/notes.md"),
                scope: ActionScope()
            )
        )
        let verdict = ActionPolicyEngine.evaluate(action: action)
        #expect(verdict.explanation.ruleID != ActionPolicyEngine.Builtin.workingTreeDiscard.ruleID)
        #expect(verdict.explanation.ruleID != ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(
            verdict.decision == .reviewEligible(fallback: ActionPolicyEngine.Builtin.uncovered)
        )

        let packDeny = Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "git reset --hard destroys uncommitted changes."
        )
        let withFallback = ActionPolicyEngine.evaluate(
            action: action,
            policy: EffectiveActionPolicy(packFallback: .deny(packDeny))
        )
        #expect(withFallback.decision == .hardDeny(packDeny))
        #expect(withFallback.explanation.ruleID != ActionPolicyEngine.Builtin.workingTreeDiscard.ruleID)
        #expect(withFallback.explanation.ruleID != ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
    }

    @Test func proposedActionFile_roundTripAndOldShellWireStillDecodes() throws {
        let action = ProposedAction.file(
            FileAction(
                fingerprint: ActionFingerprint(rawValue: "file:claude:sess:/tmp/ws:edit:/tmp/a.md"),
                file: FileToolAction(
                    kind: .edit,
                    path: FileToolPath(rawValue: "/tmp/a.md")
                ),
                effects: ActionEffects(),
                resources: ActionResources(path: "/tmp/a.md"),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/ws"))
            )
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(ProposedAction.self, from: data)
        #expect(decoded == action)
        guard case .file(let fileAction) = decoded else {
            Issue.record("expected ProposedAction.file after round-trip")
            return
        }
        #expect(fileAction.file.kind == .edit)
        #expect(fileAction.resources.path == "/tmp/a.md")
        #expect(decoded.supportingCommand == nil)

        let json = """
        {
          "id": "legacy-empty",
          "identity": {"session": "sess", "agent": "pi"},
          "action": {
            "shell": {
              "_0": {
                "fingerprint": "pi:sess:/tmp/ws:git reset --hard",
                "effects": {"kinds": []},
                "resources": {},
                "scope": {"workingDirectory": "/tmp/ws"},
                "supportingCommand": "git reset --hard"
              }
            }
          },
          "reason": "hostAsk",
          "continuation": {"kind": "hostNative"},
          "timeoutPolicy": "keepWaiting",
          "createdAt": "2023-11-14T22:13:20Z",
          "expiresAt": "2023-11-14T23:13:20Z",
          "state": {"kind": "awaitingHuman"}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pending = try decoder.decode(PendingApproval.self, from: Data(json.utf8))
        guard case .shell(let shell) = pending.action else {
            Issue.record("old .shell wire must still decode")
            return
        }
        #expect(shell.supportingCommand?.rawValue == "git reset --hard")
        #expect(pending.action.supportingCommand?.rawValue == "git reset --hard")
    }
}

import Foundation
import Testing
import RVDomain

@Suite("ShellAction")
struct ShellActionCodableTests {
    @Test func decode_rejectsEffectsThatDisagreeWithSubject() throws {
        var object = try jsonObject(analyzedForcePush())
        object["effects"] = ["kinds": [ActionEffectKind.localBranchCreate.rawValue]]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ShellAction.self, from: data)
        }
    }

    @Test func decode_absentBagUsesSubjectProjection() throws {
        var object = try jsonObject(analyzedForcePush())
        object.removeValue(forKey: "effects")
        object.removeValue(forKey: "resources")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ShellAction.self, from: data)
        #expect(decoded == analyzedForcePush())
    }

    @Test func analyzedShell_roundTripsEqual() throws {
        let shell = analyzedForcePush()
        let decoded = try JSONDecoder().decode(
            ShellAction.self,
            from: JSONEncoder().encode(shell)
        )
        #expect(decoded == shell)
        #expect(decoded.effects.kinds == [.remoteSharedBranchMutation])
        #expect(decoded.resources.remoteName == "origin")
        #expect(decoded.resources.branchName == "main")
        #expect(decoded.analysis == .git(.push(remote: "origin", refspec: "main", force: .force)))
    }

    @Test func effectOnlyForcePushFixture_keepsNilAnalysis() {
        guard case .shell(let shell) = ActionPolicyFixtures.forcePush() else {
            Issue.record("expected shell")
            return
        }
        #expect(shell.analysis == nil)
        #expect(shell.effects == ActionEffects(kinds: [.remoteSharedBranchMutation]))
        #expect(shell.resources.remoteName == "origin")
        #expect(shell.resources.branchName == "main")
    }

    private func analyzedForcePush() -> ShellAction {
        ShellAction(
            fingerprint: ActionFingerprint(rawValue: "fp-analyzed-push"),
            scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/ws")),
            supportingCommand: ShellCommand(rawValue: "git push --force origin main"),
            analysis: .git(.push(remote: "origin", refspec: "main", force: .force))
        )
    }

    private func jsonObject(_ shell: ShellAction) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(shell)) as? [String: Any]
        )
    }
}

@Suite("AgentNormalization")
struct AgentNormalizationShellTests {
    @Test func gitSubject_derivesEffectsFromSubject() throws {
        let git = GitAction.push(remote: "origin", refspec: "main", force: .force)
        let action = try ProposedAction.process(
            host: .pi,
            session: nil,
            cwd: WorkingDirectory(validating: "/tmp/ws"),
            command: ShellCommand(rawValue: "git push --force origin main"),
            analysis: .git(git)
        ).get()
        #expect(action.effects == git.effects)
        #expect(action.resources == git.resources)
        #expect(action.gitAction == git)
    }

    @Test func unknown_staysEffectOnly() throws {
        let action = try ProposedAction.process(
            host: .pi,
            session: nil,
            cwd: nil,
            command: ShellCommand(rawValue: "echo hello"),
            analysis: .unknown
        ).get()
        guard case .shell(let shell) = action else {
            Issue.record("expected shell")
            return
        }
        #expect(shell.analysis == nil)
        #expect(shell.effects.kinds.isEmpty)
    }
}

@Suite("ReviewSanitizer")
struct ReviewSanitizerShellTests {
    @Test func analyzedShell_keepsEffectsAsSubjectProjection() {
        let push = GitAction.push(
            remote: "https://ghp_exampletoken@github.com/org/repo.git",
            refspec: "main",
            force: .force
        )
        let sanitized = ReviewSanitizer.sanitize(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "fp-sanitize"),
                supportingCommand: ShellCommand(rawValue: "git push --force"),
                analysis: .git(push)
            )
        )
        #expect(sanitized.effects == sanitized.gitAction?.effects)
        #expect(sanitized.resources == sanitized.gitAction?.resources)
        #expect(sanitized.effects.kinds == [.remoteSharedBranchMutation])
        #expect(sanitized.resources.remoteName?.contains("ghp_") == false)
    }
}

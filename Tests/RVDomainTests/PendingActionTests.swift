import Testing
import RVDomain

@Suite("EvaluationResult.pendingAction")
struct PendingActionTests {
    @Test func forcePush_usesHostDoorFingerprintNotAnalyzerShellGit() throws {
        let host = HookHost.pi
        let session = try #require(SessionID(validating: "sess"))
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let command = ShellCommand(rawValue: "git push --force origin feature")
        let git = GitAction.push(
            remote: "origin",
            refspec: "feature",
            force: .force,
            delete: false
        )
        let result = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "push-force-long"),
                    reason: "force-push"
                ),
                matched: nil
            ),
            matchingView: MatchingView(command.rawValue),
            analysis: .git(git)
        )

        let action = result.pendingAction(
            host: host,
            session: session,
            cwd: cwd,
            command: command
        )
        let hostDoor = ActionFingerprint.make(
            host: host,
            session: session,
            cwd: cwd,
            command: command
        )
        let analyzer = git.proposedAction(command: command, workingDirectory: cwd)

        #expect(action.fingerprint == hostDoor)
        #expect(action.fingerprint != analyzer.fingerprint)
        #expect(action.fingerprint.rawValue.hasPrefix("shell:git") == false)
        #expect(action.effects.kinds.contains(.remoteSharedBranchMutation))
        #expect(action.resources.remoteName == "origin")
        #expect(action.resources.branchName == "feature")
        #expect(action.scope.workingDirectory == cwd)
        #expect(action.supportingCommand == command)
    }

    @Test func wrappedGit_stillTakesInnermostGitEffects() throws {
        let host = HookHost.pi
        let session = try #require(SessionID(validating: "sess"))
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let command = ShellCommand(rawValue: "bash -c 'git push --force origin feature'")
        let result = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "push-force-long"),
                    reason: "force-push"
                ),
                matched: nil
            ),
            matchingView: MatchingView(command.rawValue),
            analysis: .git(
                .push(remote: "origin", refspec: "feature", force: .force, delete: false)
            ).wrapping([.bash])
        )

        let action = result.pendingAction(
            host: host,
            session: session,
            cwd: cwd,
            command: command
        )
        #expect(
            action.fingerprint
                == ActionFingerprint.make(host: host, session: session, cwd: cwd, command: command)
        )
        #expect(action.effects.kinds.contains(.remoteSharedBranchMutation))
    }

    @Test func filesystemAnalysis_copiesEffectsAndResources() throws {
        let host = HookHost.grok
        let cwd = try #require(WorkingDirectory(validating: "/repo"))
        let command = ShellCommand(rawValue: "rm Sources/Foo.swift")
        let target = FilesystemTarget(
            apparent: "Sources/Foo.swift",
            canonical: "/repo/Sources/Foo.swift",
            scope: .insideRepository,
            kind: .sourceCode
        )
        let filesystem = FilesystemAction.delete(targets: [target], recursive: false, force: false)
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView(command.rawValue),
            analysis: .filesystem(filesystem)
        )

        let action = result.pendingAction(
            host: host,
            session: nil,
            cwd: cwd,
            command: command
        )
        #expect(
            action.fingerprint
                == ActionFingerprint.make(host: host, session: nil, cwd: cwd, command: command)
        )
        #expect(action.effects == filesystem.effects)
        #expect(action.resources == filesystem.resources)
        #expect(action.fingerprint.rawValue.hasPrefix("shell:fs") == false)
    }

    @Test(arguments: [SemanticAnalysis.unknown, .unwrapLimited])
    func unknownOrUnwrapLimited_keepsHostDoorFingerprintWithEmptyEffects(
        analysis: SemanticAnalysis
    ) throws {
        let host = HookHost.codex
        let session = try #require(SessionID(validating: "s1"))
        let command = ShellCommand(rawValue: "python -c mystery(payload)")
        let result = EvaluationResult(
            outcome: .deny(ActionPolicyEngine.Builtin.unwrapLimited, matched: nil),
            matchingView: MatchingView(command.rawValue),
            analysis: analysis
        )

        let action = result.pendingAction(
            host: host,
            session: session,
            cwd: nil,
            command: command
        )
        #expect(
            action.fingerprint
                == ActionFingerprint.make(
                    host: host,
                    session: session,
                    cwd: nil,
                    command: command
                )
        )
        #expect(action.effects.kinds.isEmpty)
        #expect(action.resources.path == nil)
        #expect(action.fingerprint.rawValue.hasPrefix("shell:") == false)
    }
}

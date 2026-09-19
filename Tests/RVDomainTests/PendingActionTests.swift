import Foundation
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
            force: .force
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
        #expect(action.gitAction == git)
        guard case .shell(let shell) = action else {
            Issue.record("expected shell pending action")
            return
        }
        #expect(shell.filesystemAction == nil)
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
                .push(remote: "origin", refspec: "feature", force: .force)
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
        #expect(
            action.gitAction
                == GitAction.push(remote: "origin", refspec: "feature", force: .force)
        )
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
        #expect(action.gitAction == nil)
        guard case .shell(let shell) = action else {
            Issue.record("expected shell pending action")
            return
        }
        #expect(shell.filesystemAction == filesystem)
        #expect(shell.gitAction == nil)
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
        #expect(action.gitAction == nil)
        guard case .shell(let shell) = action else {
            Issue.record("expected shell pending action")
            return
        }
        #expect(shell.filesystemAction == nil)
    }

    @Test func oldEmptyEffectPendingJSON_stillDecodes() throws {
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
                "supportingCommand": "git reset --hard",
                "legacyExtra": true
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
        let decoded = try decoder.decode(PendingApproval.self, from: Data(json.utf8))
        #expect(decoded.id.rawValue == "legacy-empty")
        #expect(decoded.fingerprint.rawValue == "pi:sess:/tmp/ws:git reset --hard")
        #expect(decoded.action.effects.kinds.isEmpty)
        #expect(decoded.action.resources.path == nil)
        #expect(decoded.action.supportingCommand?.rawValue == "git reset --hard")
        #expect(decoded.state == .awaitingHuman)
        #expect(decoded.action.gitAction == nil)
        guard case .shell(let shell) = decoded.action else {
            Issue.record("expected shell pending action")
            return
        }
        #expect(shell.filesystemAction == nil)
    }

    @Test func sanitize_keepsGitPushAnalysis() {
        let push = GitAction.push(remote: "origin", refspec: "feature", force: .force)
        let shell = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "host:sess:/tmp:git push --force origin feature"),
            effects: push.effects,
            resources: push.resources,
            supportingCommand: ShellCommand(rawValue: "git push --force origin feature"),
            gitAction: push
        )
        let sanitized = ReviewSanitizer.sanitize(shell)
        #expect(sanitized.gitAction == push)
        #expect(sanitized.filesystemAction == nil)
    }

    @Test func sanitize_keepsFilesystemAnalysis() {
        let filesystem = FilesystemAction.delete(
            targets: [
                FilesystemTarget(
                    apparent: "Sources/Foo.swift",
                    canonical: "/repo/Sources/Foo.swift",
                    scope: .insideRepository,
                    kind: .sourceCode
                ),
            ],
            recursive: false,
            force: false
        )
        let shell = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "host::/repo:rm Sources/Foo.swift"),
            effects: filesystem.effects,
            resources: filesystem.resources,
            supportingCommand: ShellCommand(rawValue: "rm Sources/Foo.swift"),
            filesystemAction: filesystem
        )
        let sanitized = ReviewSanitizer.sanitize(shell)
        #expect(sanitized.filesystemAction == filesystem)
        #expect(sanitized.gitAction == nil)
    }

    @Test func sanitize_redactsCredentialShapedGitPushAnalysis() throws {
        let push = GitAction.push(
            remote: "https://ghp_exampletoken@github.com/org/repo.git",
            refspec: "main",
            force: .force
        )
        let shell = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "host:sess:/tmp:git push --force"),
            effects: push.effects,
            resources: push.resources,
            supportingCommand: ShellCommand(rawValue: "git push --force origin main"),
            gitAction: push
        )

        let sanitized = ReviewSanitizer.sanitize(shell)
        guard case .push(let remote, let refspec, let force)? = sanitized.gitAction else {
            Issue.record("expected sanitized git push analysis")
            return
        }
        #expect(force == .force)
        #expect(remote?.contains("ghp_") == false)
        #expect(refspec?.contains("ghp_") == false)
        #expect(sanitized.resources.remoteName?.contains("ghp_") == false)
        #expect(sanitized.resources == sanitized.gitAction?.resources)

        let sanitizedJSON = String(decoding: try JSONEncoder().encode(sanitized), as: UTF8.self)
        #expect(sanitizedJSON.contains("ghp_") == false)
        #expect(sanitizedJSON.contains("gitAction") == true)

        let request = ReviewRequest(
            action: .shell(shell),
            context: ReviewContext(repository: RepositoryReviewContext(name: "rv"))
        )
        guard case .shell(let requestShell) = request.action else {
            Issue.record("expected shell review action")
            return
        }
        guard case .push(let requestRemote, let requestRefspec, let requestForce)? =
            requestShell.gitAction
        else {
            Issue.record("expected review request to keep git push analysis")
            return
        }
        #expect(requestForce == .force)
        #expect(requestRemote?.contains("ghp_") == false)
        #expect(requestRefspec?.contains("ghp_") == false)
        #expect(requestShell.resources.remoteName?.contains("ghp_") == false)

        let requestJSON = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(requestJSON.contains("ghp_") == false)
        #expect(requestJSON.contains("gitAction") == true)
    }

    @Test func sanitize_redactsCredentialShapedFilesystemAnalysis() throws {
        let filesystem = FilesystemAction.delete(
            targets: [
                FilesystemTarget(
                    apparent: "ghp_exampletoken",
                    canonical: "/tmp/ghp_exampletoken/id",
                    scope: .insideRepository,
                    kind: .unknown
                ),
            ],
            recursive: false,
            force: true
        )
        let shell = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "host::/tmp:rm ghp_exampletoken"),
            effects: filesystem.effects,
            resources: filesystem.resources,
            supportingCommand: ShellCommand(rawValue: "rm ghp_exampletoken"),
            filesystemAction: filesystem
        )

        let sanitized = ReviewSanitizer.sanitize(shell)
        guard case .delete(let targets, let recursive, let force)? = sanitized.filesystemAction
        else {
            Issue.record("expected sanitized filesystem delete analysis")
            return
        }
        #expect(recursive == false)
        #expect(force == true)
        let target = try #require(targets.first)
        #expect(target.apparent.contains("ghp_") == false)
        #expect(target.canonical.contains("ghp_") == false)
        #expect(sanitized.resources.path?.contains("ghp_") == false)
        #expect(sanitized.resources == sanitized.filesystemAction?.resources)

        let sanitizedJSON = String(decoding: try JSONEncoder().encode(sanitized), as: UTF8.self)
        #expect(sanitizedJSON.contains("ghp_") == false)
        #expect(sanitizedJSON.contains("filesystemAction") == true)

        let request = ReviewRequest(
            action: .shell(shell),
            context: ReviewContext(repository: RepositoryReviewContext(name: "rv"))
        )
        guard case .shell(let requestShell) = request.action else {
            Issue.record("expected shell review action")
            return
        }
        guard case .delete(let requestTargets, _, let requestForce)? =
            requestShell.filesystemAction
        else {
            Issue.record("expected review request to keep filesystem delete analysis")
            return
        }
        #expect(requestForce == true)
        let requestTarget = try #require(requestTargets.first)
        #expect(requestTarget.apparent.contains("ghp_") == false)
        #expect(requestTarget.canonical.contains("ghp_") == false)
        #expect(requestShell.resources.path?.contains("ghp_") == false)

        let requestJSON = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(requestJSON.contains("ghp_") == false)
        #expect(requestJSON.contains("filesystemAction") == true)
    }

    @Test func shellAction_gitOnlyEncodeOmitsFilesystemAndAnalysisKeys() throws {
        let shell = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "fp-git-only"),
            gitAction: .push(remote: "origin", refspec: "main", force: .none)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(shell)) as? [String: Any]
        )
        #expect(object["gitAction"] != nil)
        #expect(object.keys.contains("gitAction") == true)
        #expect(object.keys.contains("filesystemAction") == false)
        #expect(object.keys.contains("analysis") == false)
    }

    @Test func shellAction_decodeRejectsBothGitAndFilesystemKeys() throws {
        let git = GitAction.push(remote: "origin", refspec: "main", force: .none)
        let filesystem = FilesystemAction.delete(
            targets: [
                FilesystemTarget(
                    apparent: "a",
                    canonical: "/repo/a",
                    scope: .insideRepository,
                    kind: .sourceCode
                ),
            ],
            recursive: false,
            force: false
        )
        let gitShell = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "fp-git"),
            gitAction: git
        )
        let filesystemShell = ShellAction(
            fingerprint: ActionFingerprint(rawValue: "fp-fs"),
            filesystemAction: filesystem
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(gitShell)) as? [String: Any]
        )
        let filesystemObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(filesystemShell))
                as? [String: Any]
        )
        object["filesystemAction"] = filesystemObject["filesystemAction"]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ShellAction.self, from: data)
        }
    }
}

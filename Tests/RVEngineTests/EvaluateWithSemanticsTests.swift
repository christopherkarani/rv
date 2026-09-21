import Testing
import RVDomain
@testable import RVEngine

/// The evaluation door: pack evaluate → unwrap → probe → analyze → apply,
/// with pack deny / indeterminate as the floor.
@Suite("EvaluateWithSemantics")
struct EvaluateWithSemanticsTests {
    @Test func packAllow_semanticGitDeny_tightens() throws {
        // `feature` is not a name-based shared branch; probed HEAD `main`
        // is. Dropping the probed world would demote this to `remoteBranchAsk`.
        let command = "bash -c 'git push --force-with-lease origin feature'"
        let result = try runDoor(
            command,
            gitProbe: { _ in .probed(GitAnalysisContext(currentBranch: "main")) }
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("wrapped force-with-lease to shared branch must deny")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(result.analysis.wrappers == [.bash])
        #expect(result.analysis.gitAction != nil)
    }

    @Test func missingCorePacks_staysIndeterminateAndAnalyzes() throws {
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: [], using: engine)
        let result = evaluateWithSemantics(
            EvaluationRequest(
                command: ShellCommand(rawValue: "bash -c 'git reset --hard'"),
                enabledPacks: dayOnePackIDs
            ),
            packs: [],
            engine: engine,
            compiled: compiled
        )
        #expect(result.decision == .indeterminate(.corePacksUnavailable))
        #expect(result.analysis.wrappers == [.bash])
        #expect(result.analysis.gitAction == .reset(mode: .hard, target: nil))
    }

    @Test func wrappedBashResetHard_equalsComposedDeny() throws {
        let command = "bash -c 'git reset --hard'"
        let pack = try runPack(command)
        guard case .deny(let packDeny) = pack.decision else {
            Issue.record("pack must still see git reset --hard")
            return
        }
        let door = try runDoor(command)
        guard case .deny(let deny) = door.decision else {
            Issue.record("door must keep today's composed deny, got \(door.decision)")
            return
        }
        #expect(deny.ruleID == packDeny.ruleID)
        #expect(deny.ruleID == RuleID(pack: .coreGit, pattern: "reset-hard"))
        #expect(door.analysis.innermost == .git(.reset(mode: .hard, target: nil)))
        #expect(door.analysis.wrappers == [.bash])
    }

    @Test func packDeny_staysFloor() throws {
        let command = "sudo env FOO=bar sh -c 'git reset --hard'"
        let result = try runDoor(command)
        guard case .deny(let deny) = result.decision else {
            Issue.record("pack deny must survive the door")
            return
        }
        #expect(deny.ruleID == RuleID(pack: .coreGit, pattern: "reset-hard"))
        #expect(result.analysis.gitAction == .reset(mode: .hard, target: nil))
        #expect(result.analysis.wrappers == [.sudo, .env, .sh])
    }

    @Test func unwrapLimited_failClosed() throws {
        let result = try runDoor(#"python3 -c "$CMD""#)
        guard case .deny(let deny) = result.decision else {
            Issue.record("unknown python -c payload must fail-closed, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(result.analysis.innermost == .unwrapLimited)
    }

    @Test func capturedPythonAssignment_allows() throws {
        let result = try runDoor(#"python3 -c "x = 1""#)
        #expect(result.decision == .allow)
        #expect(result.analysis.innermost != .unwrapLimited)
    }

    @Test func capturedPythonMystery_allows() throws {
        let result = try runDoor(#"python -c "mystery(payload)""#)
        #expect(result.decision == .allow)
        #expect(result.analysis.innermost != .unwrapLimited)
    }

    @Test func indeterminate_staysFloor() throws {
        let huge = String(repeating: "a", count: commandByteCap + 1)
        let result = try runDoor(huge)
        #expect(result.decision == .indeterminate(.commandTooLarge))
    }

    @Test func probeReceivesUnwrappedOutcome() throws {
        var probed: UnwrapOutcome?
        let result = try runDoor(
            "bash -c 'echo hi'",
            filesystemProbe: { outcome in
                probed = outcome
                return .probed(
                    FilesystemAnalysisContext(
                        workingDirectory: WorkingDirectory(validating: "/repo"),
                        repositoryRoot: RepositoryRoot(validating: "/repo")
                    )
                )
            }
        )
        guard case .complete(let unwrapped) = probed else {
            Issue.record("probe must see the unwrapped outcome")
            return
        }
        #expect(unwrapped.command.rawValue == "echo hi")
        #expect(unwrapped.layers == [.bash])
        #expect(result.decision == .allow)
    }

    @Test func gitProbeReceivesUnwrappedOutcome_defaultStaysUnprobed() throws {
        var probed: UnwrapOutcome?
        let result = try runDoor(
            "bash -c 'git push --force-with-lease'",
            gitProbe: { outcome in
                probed = outcome
                return .unprobed
            }
        )
        guard case .complete(let unwrapped) = probed else {
            Issue.record("gitProbe must see the unwrapped outcome")
            return
        }
        #expect(unwrapped.command.rawValue == "git push --force-with-lease")
        #expect(unwrapped.layers == [.bash])
        #expect(result.decision == .allow)
        #expect(result.analysis.wrappers == [.bash])
        guard case .git(.push(_, let refspec, .forceWithLease)) = result.analysis.innermost
        else {
            Issue.record("unprobed implicit push must parse, got \(result.analysis)")
            return
        }
        #expect(refspec == nil)
    }

    @Test func packAllow_filesystemDeny_viaProbeFacts() throws {
        let result = try runDoor(
            "bash -c 'echo hi > ../outside-file'",
            filesystemProbe: { _ in
                .probed(
                    FilesystemAnalysisContext(
                        workingDirectory: WorkingDirectory(validating: "/repo"),
                        repositoryRoot: RepositoryRoot(validating: "/repo")
                    )
                )
            }
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("wrapped out-of-repo write must deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
        #expect(result.analysis.filesystemAction?.resources.filesystemScope == .outsideRepository)
    }

    @Test func defaultProbe_packAllowWrite_staysAllow() throws {
        let result = try runDoor("echo hi > file")
        #expect(result.decision == .allow)
        #expect(result.analysis.filesystemAction?.operationKind == .write)
    }

    @Test func defaultProbe_envChdirWrite_staysAllow() throws {
        let result = try runDoor("env -C /tmp echo hi > file")
        #expect(result.decision == .allow)
        #expect(result.analysis.filesystemAction?.operationKind == .write)
        #expect(result.analysis.filesystemAction?.resources.filesystemScope == .unknown)
    }

    @Test func defaultProbe_envChdirProtectedPath_stillDenies() throws {
        let result = try runDoor("env -C /tmp/.ssh rm config")
        guard case .deny(let deny) = result.decision else {
            Issue.record(
                "unprobed unwrap cwd must still catalog-deny, got \(result.decision)"
            )
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        #expect(result.analysis.wrappers == [.env])
        #expect(
            result.analysis.filesystemAction?.primaryTarget?.scope
                == .protectedPath(SecretPathMatch(pattern: "home-ssh", category: .ssh))
        )
    }

    @Test func plainAllow_staysAllow() throws {
        let result = try runDoor("git status")
        #expect(result.decision == .allow)
    }

    @Test func defaultProbe_forceWithLeaseNoRefspec_typedGitPushMain_doesNotMatch() throws {
        let rule = TypedRule(
            id: RuleID(pack: .typedGit, pattern: "force-with-lease-main"),
            predicate: .gitPush(force: .exactly(.forceWithLease), branch: "main"),
            verdict: .deny,
            origin: .machine
        )
        let result = try runDoor(
            "git push --force-with-lease",
            policy: EffectiveActionPolicy(rules: [rule])
        )
        #expect(result.decision == .allow)
        guard case .git(.push(_, let refspec, .forceWithLease)) = result.analysis else {
            Issue.record("unprobed implicit push must parse, got \(result.analysis)")
            return
        }
        #expect(refspec == nil)
    }

    @Test func gitProbe_forceWithLeaseNoRefspec_probedMain_typedAllowCannotBeatSharedWall() throws {
        let rule = TypedRule(
            id: RuleID(pack: .typedGit, pattern: "allow-force-with-lease-main"),
            predicate: .gitPush(force: .exactly(.forceWithLease), branch: "main"),
            verdict: .allow,
            origin: .machine
        )
        let result = try runDoor(
            "git push --force-with-lease",
            gitProbe: { _ in
                .probed(GitAnalysisContext(currentBranch: "main"))
            },
            policy: EffectiveActionPolicy(rules: [rule])
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("probed implicit HEAD main must hard-deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(result.boundReview == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        guard case .git(.push(_, let refspec, .forceWithLease)) = result.analysis else {
            Issue.record("probed implicit push must parse refspec main, got \(result.analysis)")
            return
        }
        #expect(refspec == "main")
    }
}

private func runPack(_ command: String) throws -> EvaluationResult {
    try runSemanticsPack(command)
}

private func runDoor(
    _ command: String,
    gitProbe: (UnwrapOutcome) -> GitAnalysisWorld = { _ in .unprobed },
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisWorld = { _ in .unprobed },
    policy: EffectiveActionPolicy = .empty
) throws -> EvaluationResult {
    try runSemanticsDoor(
        command,
        gitProbe: gitProbe,
        filesystemProbe: filesystemProbe,
        policy: policy
    )
}

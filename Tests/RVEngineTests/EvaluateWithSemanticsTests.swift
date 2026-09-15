import Testing
import RVDomain
@testable import RVEngine

/// The evaluation door: pack evaluate → unwrap → probe → analyze → apply,
/// with pack deny / indeterminate as the floor.
@Suite("EvaluateWithSemantics")
struct EvaluateWithSemanticsTests {
    @Test func packAllow_semanticGitDeny_tightens() throws {
        // `feature` is not a name-based shared branch; dropping the probed
        // world would demote this to `remoteBranchAsk` instead of the wall.
        let command = "bash -c 'git push --force-with-lease origin feature'"
        let result = try runDoor(
            command,
            gitProbe: { _ in .probed(GitAnalysisContext(isSharedBranch: true)) }
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
            patterns: engine,
            compiled: compiled
        )
        #expect(result.decision == .indeterminate(.corePacksUnavailable))
        #expect(result.analysis.wrappers == [.bash])
        #expect(result.analysis.gitAction == .reset(mode: .hard, target: nil))
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
        let result = try runDoor(#"python -c "mystery(payload)""#)
        guard case .deny(let deny) = result.decision else {
            Issue.record("unreliable python must fail-closed, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(result.analysis.innermost == .unwrapLimited)
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
        #expect(result.analysis.filesystemAction?.primaryTarget?.scope == .protectedPath)
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
        guard case .git(.push(_, let refspec, .forceWithLease, false)) = result.analysis else {
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
                .probed(GitAnalysisContext(currentBranch: "main", isSharedBranch: true))
            },
            policy: EffectiveActionPolicy(rules: [rule])
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("probed implicit HEAD main must hard-deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(result.boundReview == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        guard case .git(.push(_, let refspec, .forceWithLease, false)) = result.analysis else {
            Issue.record("probed implicit push must parse refspec main, got \(result.analysis)")
            return
        }
        #expect(refspec == "main")
    }
}

private func runDoor(
    _ command: String,
    gitProbe: (UnwrapOutcome) -> GitAnalysisWorld = { _ in .unprobed },
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisWorld = { _ in .unprobed },
    policy: EffectiveActionPolicy = .empty
) throws -> EvaluationResult {
    let packs = [
        PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["rm"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "rm-rf-general",
                    pattern: #"rm\s+-rf"#,
                    severity: .high,
                    reason: "rm -rf is destructive"
                ),
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [NamedPattern(name: "checkout-new-branch", pattern: #"git\s+checkout\s+-b\s+"#)],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: #"git\s+reset\s+--hard"#,
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes"
                ),
            ]
        ),
    ]
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluateWithSemantics(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        patterns: engine,
        compiled: compiled,
        gitProbe: gitProbe,
        filesystemProbe: filesystemProbe,
        policy: policy
    )
}

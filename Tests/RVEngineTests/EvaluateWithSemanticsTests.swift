import Testing
import RVDomain
@testable import RVEngine

/// The evaluation door: pack evaluate → unwrap → probe → analyze → apply,
/// with pack deny / indeterminate as the floor.
@Suite("EvaluateWithSemantics")
struct EvaluateWithSemanticsTests {
    @Test func packAllow_semanticGitDeny_tightens() throws {
        // `feature` is not a name-based shared branch; dropping `gitContext`
        // would demote this to `remoteBranchAsk` instead of the shared-branch wall.
        let command = "bash -c 'git push --force-with-lease origin feature'"
        let result = try runDoor(
            command,
            gitContext: GitAnalysisContext(isSharedBranch: true)
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
                return FilesystemAnalysisContext(
                    workingDirectory: WorkingDirectory(validating: "/repo"),
                    repositoryRoot: RepositoryRoot(validating: "/repo")
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
                FilesystemAnalysisContext(
                    workingDirectory: WorkingDirectory(validating: "/repo"),
                    repositoryRoot: RepositoryRoot(validating: "/repo")
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

    @Test func plainAllow_staysAllow() throws {
        let result = try runDoor("git status")
        #expect(result.decision == .allow)
    }
}

private func runDoor(
    _ command: String,
    gitContext: GitAnalysisContext = .empty,
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisContext = { _ in .empty },
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
        gitContext: gitContext,
        filesystemProbe: filesystemProbe,
        policy: policy
    )
}

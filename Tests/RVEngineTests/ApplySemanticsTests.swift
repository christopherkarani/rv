import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplySemantics")
struct ApplySemanticsTests {
    private let repo = FilesystemAnalysisContext(
        workingDirectory: WorkingDirectory(validating: "/repo"),
        repositoryRoot: RepositoryRoot(validating: "/repo")
    )

    @Test func wrappedGitReset_matchesDirectDecision() throws {
        let directCommand = "git reset --hard"
        let wrappedCommand = "bash -c 'git reset --hard'"
        let directPack = try runSemanticsPack(directCommand)
        let wrappedPack = try runSemanticsPack(wrappedCommand)
        let direct = applySemantics(
            pack: directPack,
            command: ShellCommand(rawValue: directCommand)
        )
        let wrapped = applySemantics(
            pack: wrappedPack,
            command: ShellCommand(rawValue: wrappedCommand)
        )
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.bash])
    }

    @Test func packDeny_isFloorOnWrappedReset() throws {
        let command = "sudo env FOO=bar sh -c 'git reset --hard'"
        let pack = try runSemanticsPack(command)
        guard case .deny(let packDeny) = pack.decision else {
            Issue.record("sample pack must still see git reset --hard")
            return
        }
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: command)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("composed must keep pack deny")
            return
        }
        #expect(deny.ruleID == packDeny.ruleID)
        #expect(composed.analysis.gitAction == .reset(mode: .hard, target: nil))
        #expect(composed.analysis.wrappers == [.sudo, .env, .sh])
    }

    @Test func echoQuotedRm_staysAllow() throws {
        let pack = try runSemanticsPack("echo 'rm -rf /'")
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: "echo 'rm -rf /'"),
            filesystemContext: repo
        )
        #expect(composed.decision == .allow)
        #expect(composed.analysis.filesystemAction == nil)
    }

    @Test func unwrapLimit_neverAutoAllows() throws {
        let pack = try runSemanticsPack(#"python -c "mystery(payload)""#)
        #expect(pack.decision == .allow)
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: #"python -c "mystery(payload)""#)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("unreliable python must fail-closed, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(composed.analysis.innermost == .unwrapLimited)
    }

    @Test func wrappedForceWithLease_isDeniedBySemantics() throws {
        let command = "bash -c 'git push --force-with-lease origin main'"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            gitContext: GitAnalysisContext(isSharedBranch: true)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("wrapped force-with-lease to main must deny")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(composed.analysis.gitAction != nil)
    }

    @Test func wrappedOutOfRepoWrite_isDeniedByBoundary() throws {
        let command = "bash -c 'echo hi > ../outside-file'"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemContext: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("wrapped out-of-repo write must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
        #expect(composed.analysis.wrappers == [.bash])
        #expect(composed.analysis.filesystemAction?.resources.filesystemScope == .outsideRepository)
    }

    @Test func pythonRemoveProtected_isDeniedBySemantics() throws {
        // Bare `link` is not a secret-path token, so packs allow. The fact
        // maps it to a protected destination — wrappers must not lift that floor.
        let command = #"python -c "os.remove('link')""#
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let context = FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo"),
            facts: [
                FilesystemPathFact(
                    apparent: "link",
                    canonical: "/isolated-home/.ssh/id_rsa",
                    followedSymlink: true,
                    resolution: .resolved
                ),
            ]
        )
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemContext: context
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("protected path via python must deny")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        #expect(composed.analysis.wrappers == [.python])
        #expect(composed.analysis.filesystemAction?.primaryTarget?.scope == .protectedPath)
    }

    @Test func unquotedBashDashC_keepsPackDenyAndUnwrapLimited() throws {
        let command = "bash -c git reset --hard"
        let pack = try runSemanticsPack(command)
        guard case .deny(let packDeny) = pack.decision else {
            Issue.record("unquoted -c still has pack-visible git reset --hard")
            return
        }
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: command)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("unquoted -c must not silent-allow, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == packDeny.ruleID)
        #expect(composed.analysis.innermost == .unwrapLimited)
    }

    @Test func dollarPayloadDashC_neverAutoAllows() throws {
        let command = "bash -c $CMD"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: command)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("$ -c must fail-closed, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(composed.analysis.innermost == .unwrapLimited)
    }

    @Test func pythonPrintOsSystem_neverAutoAllows() throws {
        let command = #"python -c "print(os.system('git reset --hard'))""#
        let pack = try runSemanticsPack(command)
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: command)
        )
        guard case .deny = composed.decision else {
            Issue.record("print(os.system) must not silent-allow, got \(composed.decision)")
            return
        }
        #expect(composed.analysis.innermost == .git(.reset(mode: .hard, target: nil)))
        #expect(composed.analysis.wrappers == [.python])
    }

    @Test func packIndeterminate_isNotLiftedByLimit() {
        let pack = EvaluationResult(
            outcome: .indeterminate(.corePacksUnavailable),
            matchingView: MatchingView("python -c mystery")
        )
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: #"python -c "mystery(payload)""#)
        )
        #expect(composed.decision == .indeterminate(.corePacksUnavailable))
        #expect(composed.analysis.innermost == .unwrapLimited)
    }
}

private func runSemanticsPack(_ command: String) throws -> EvaluationResult {
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
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
}

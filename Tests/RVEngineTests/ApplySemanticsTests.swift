import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplySemantics")
struct ApplySemanticsTests {
    private let repo = FilesystemAnalysisWorld.probed(
        FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo")
        )
    )

    @Test func wrappedGitReset_matchesDirectDecision() throws {
        let direct = try runSemanticsDoor("git reset --hard")
        let wrapped = try runSemanticsDoor("bash -c 'git reset --hard'")
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
        let composed = try runSemanticsDoor(command)
        guard case .deny(let deny) = composed.decision else {
            Issue.record("composed must keep pack deny")
            return
        }
        #expect(deny.ruleID == packDeny.ruleID)
        #expect(composed.analysis.gitAction == .reset(mode: .hard, target: nil))
        #expect(composed.analysis.wrappers == [.sudo, .env, .sh])
    }

    @Test func echoQuotedRm_staysAllow() throws {
        let composed = try runSemanticsDoor(
            "echo 'rm -rf /'",
            filesystemProbe: { _ in repo }
        )
        #expect(composed.decision == .allow)
        #expect(composed.analysis.filesystemAction == nil)
    }

    @Test func unwrapLimit_neverAutoAllows() throws {
        let command = #"python3 -c "$CMD""#
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = try runSemanticsDoor(command)
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
        let composed = try runSemanticsDoor(
            command,
            gitProbe: { _ in .probed(GitAnalysisContext(currentBranch: "main")) }
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
        let composed = try runSemanticsDoor(
            command,
            filesystemProbe: { _ in repo }
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
        let context = FilesystemAnalysisWorld.probed(
            FilesystemAnalysisContext(
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
        )
        let composed = try runSemanticsDoor(
            command,
            filesystemProbe: { _ in context }
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("protected path via python must deny")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        #expect(composed.analysis.wrappers == [.python])
        #expect(
            composed.analysis.filesystemAction?.primaryTarget?.scope
                == .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh))
        )
    }

    @Test func unprobedWorld_packAllowWrite_staysAllow() throws {
        let pack = try runSemanticsPack("echo hi > file")
        #expect(pack.decision == .allow)
        let composed = try runSemanticsDoor("echo hi > file")
        #expect(composed.decision == .allow)
        #expect(composed.analysis.filesystemAction?.operationKind == .write)
    }

    @Test func probedEmptyWorld_packAllowWrite_isFailClosedThroughAnalyze() throws {
        let pack = try runSemanticsPack("echo hi > file")
        #expect(pack.decision == .allow)
        let composed = try runSemanticsDoor(
            "echo hi > file",
            filesystemProbe: { _ in .probed(.empty) }
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record(
                "probed empty must fail-closed through analyze+apply, got \(composed.decision)"
            )
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID)
    }

    @Test func unquotedBashDashC_keepsPackDenyAndUnwrapLimited() throws {
        let command = "bash -c git reset --hard"
        let pack = try runSemanticsPack(command)
        guard case .deny(let packDeny) = pack.decision else {
            Issue.record("unquoted -c still has pack-visible git reset --hard")
            return
        }
        let composed = try runSemanticsDoor(command)
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
        let composed = try runSemanticsDoor(command)
        guard case .deny(let deny) = composed.decision else {
            Issue.record("$ -c must fail-closed, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(composed.analysis.innermost == .unwrapLimited)
    }

    @Test func pythonPrintOsSystem_neverAutoAllows() throws {
        let command = #"python -c "print(os.system('git reset --hard'))""#
        let composed = try runSemanticsDoor(command)
        guard case .deny = composed.decision else {
            Issue.record("print(os.system) must not silent-allow, got \(composed.decision)")
            return
        }
        #expect(composed.analysis.innermost == .git(.reset(mode: .hard, target: nil)))
        #expect(composed.analysis.wrappers == [.python])
    }

    @Test func packIndeterminate_isNotLiftedByLimit() throws {
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: [], using: engine)
        let composed = evaluateWithSemantics(
            EvaluationRequest(
                command: ShellCommand(rawValue: #"python3 -c "$CMD""#),
                enabledPacks: dayOnePackIDs
            ),
            packs: [],
            engine: engine,
            compiled: compiled
        )
        #expect(composed.decision == .indeterminate(.corePacksUnavailable))
        #expect(composed.analysis.innermost == .unwrapLimited)
    }
}

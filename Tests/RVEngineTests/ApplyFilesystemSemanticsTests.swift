import Foundation
import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplyFilesystemSemantics")
struct ApplyFilesystemSemanticsTests {
    private let repo = FilesystemAnalysisWorld.probed(
        FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo")
        )
    )

    @Test func inRepoWriteAndCreate_stayAllowUnderDefaultPolicy() throws {
        let write = try runFilesystemPack("echo hi > Sources/Foo.swift")
        #expect(write.decision == .allow)
        let writeComposed = applyFilesystemSemantics(
            pack: write,
            command: ShellCommand(rawValue: "echo hi > Sources/Foo.swift"),
            filesystemWorld: repo
        )
        #expect(writeComposed.decision == .allow)
        guard case .filesystem(let writeAction) = writeComposed.analysis else {
            Issue.record("expected overwrite analysis")
            return
        }
        #expect(writeAction.operationKind == .write)
        #expect(writeAction.resources.filesystemScope == .insideRepository)
        #expect(writeComposed.boundReview == nil)

        let create = try runFilesystemPack("touch new.swift")
        #expect(create.decision == .allow)
        let createComposed = applyFilesystemSemantics(
            pack: create,
            command: ShellCommand(rawValue: "touch new.swift"),
            filesystemWorld: repo
        )
        #expect(createComposed.decision == .allow)
        guard case .filesystem(let createAction) = createComposed.analysis else {
            Issue.record("expected create analysis")
            return
        }
        #expect(createAction.operationKind == .create)
        #expect(createAction.resources.filesystemScope == .insideRepository)
    }

    @Test func outOfRepoWrite_isDeniedByBoundary() throws {
        let pack = try runFilesystemPack("echo hi > ../outside-file")
        #expect(pack.decision == .allow)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "echo hi > ../outside-file"),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("out-of-repo write must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
        #expect(composed.boundReview == .deny(ActionPolicyEngine.Builtin.outsideRepository))
        guard case .filesystem(let action) = composed.analysis else {
            Issue.record("expected filesystem analysis")
            return
        }
        #expect(action.resources.filesystemScope == .outsideRepository)
        #expect(action.primaryTarget?.canonical == "/outside-file")
    }

    @Test func curlOutputDirOutside_isDeniedByBoundary() throws {
        // --output-dir prepends to relative -o names; the write lands
        // outside while the raw claim would resolve inside.
        let command = "curl -o rel --output-dir /outside http://h"
        let pack = try runFilesystemPack(command)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("output-dir escape must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func escapedVerbOutside_isDeniedByBoundary() throws {
        // Backslash-escaped spellings execute the tool; dispatch
        // unescapes pairs before matching or destinations are missed.
        let command = "c\\url -o /outside/x http://h"
        let pack = try runFilesystemPack(command)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("escaped-verb escape must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func escapedCdChain_isDeniedByBoundary() throws {
        // `c\d` moves the runtime outside while a naive tracker keeps
        // the stale inside cwd; poisoning fails the chain closed.
        let command = "c\\d /tmp && touch evil"
        let pack = try runFilesystemPack(command)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("escaped-cd chain must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func globVerbOutside_isDeniedByBoundary() throws {
        // A glob head can expand to the tool (`[c]url` with ./curl
        // present); dispatch misses it, so the dynamic-verb rule must
        // fail the segment closed instead of skipping it.
        let command = "[c]url -o /outside/x http://h"
        let pack = try runFilesystemPack(command)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("glob-verb escape must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func dynamicVerbSingle_isDeniedByBoundary() throws {
        // Pre-existing gap, same shape: an unparseable dynamic-head
        // single returned unknown → allow. Now fails closed like chains.
        let command = "$CMD -o /outside/x http://h"
        let pack = try runFilesystemPack(command)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("dynamic-verb single must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func dynamicVerbSingle_doorDeniesRatherThanAsks() throws {
        // The unresolved-invocation ask must not stand in for the boundary deny.
        let result = try runFilesystemDoor("$CMD -o /outside/x http://h") { _ in repo }
        guard case .deny(let deny) = result.decision else {
            Issue.record("dynamic-verb single must deny at the door, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func globCdChain_isDeniedByBoundary() throws {
        let command = "[c]d /tmp && touch evil"
        let pack = try runFilesystemPack(command)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("glob-cd chain must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test(.disabled("FORK-SEMANTICS FOLLOW-UP: verified allow; needs fork-aware cwd threading")) func forkPipeCwd_isDeniedByBoundary() throws {
        // FORK-SEMANTICS FOLLOW-UP (verified allow on 2026-10-07): `cd`
        // in a pipeline forks, so the runtime stays in /tmp while the
        // tracker models /repo. Correct verdict is deny; observed allow.
        let command = "cd /tmp && cd /repo | touch evil"
        let pack = try runFilesystemPack(command)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("fork-pipe chain must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test(.disabled("FORK-SEMANTICS FOLLOW-UP: verified allow; needs fork-aware cwd threading")) func forkBackgroundCwd_isDeniedByBoundary() throws {
        // FORK-SEMANTICS FOLLOW-UP (verified allow on 2026-10-07):
        // backgrounded `cd` forks; same divergence as pipes.
        let command = "cd /tmp && cd /repo & touch evil"
        let pack = try runFilesystemPack(command)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("fork-background chain must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test(.disabled("FORK-SEMANTICS FOLLOW-UP: verified allow; needs fork-aware cwd threading")) func forkSubshellCwd_isDeniedByBoundary() throws {
        // FORK-SEMANTICS FOLLOW-UP (verified allow on 2026-10-07):
        // subshell `cd` never escapes; same divergence as pipes.
        let command = "cd /tmp && (cd /repo) && touch evil"
        let pack = try runFilesystemPack(command)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("fork-subshell chain must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func symlinkEscape_usesCanonicalScopeForPolicy() throws {
        let pack = try runFilesystemPack("rm link")
        #expect(pack.decision == .allow)
        let context = FilesystemAnalysisWorld.probed(
            FilesystemAnalysisContext(
                workingDirectory: WorkingDirectory(validating: "/repo"),
                repositoryRoot: RepositoryRoot(validating: "/repo"),
                facts: [
                    FilesystemPathFact(
                        apparent: "link",
                        canonical: "/tmp/outside-file",
                        followedSymlink: true,
                        resolution: .resolved
                    ),
                ]
            )
        )
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "rm link"),
            filesystemWorld: context
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("symlink escape must deny as outside, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
        #expect(composed.analysis.filesystemAction?.primaryTarget?.canonical == "/tmp/outside-file")
        #expect(composed.analysis.filesystemAction?.primaryTarget?.scope == .outsideRepository)
    }

    @Test func unresolvedPath_isFailClosed() throws {
        let pack = try runFilesystemPack("rm file")
        #expect(pack.decision == .allow)
        let context = FilesystemAnalysisWorld.probed(
            FilesystemAnalysisContext(
                workingDirectory: WorkingDirectory(validating: "/repo"),
                repositoryRoot: RepositoryRoot(validating: "/repo"),
                facts: [
                    FilesystemPathFact(
                        apparent: "file",
                        canonical: "/repo/file",
                        resolution: .uncertain
                    ),
                ]
            )
        )
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "rm file"),
            filesystemWorld: context
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("uncertain path must fail-closed, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID)
        #expect(composed.analysis.filesystemAction?.primaryTarget?.scope == .unknown)
    }

    @Test func missingRepositoryRoot_isFailClosed() throws {
        let pack = try runFilesystemPack("echo hi > file")
        #expect(pack.decision == .allow)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "echo hi > file"),
            filesystemWorld: .probed(.empty)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("no repo root must fail-closed, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID)
    }

    @Test func unprobedEmpty_packAllowWrite_staysAllowAndAttachesAnalysis() throws {
        let pack = try runFilesystemPack("echo hi > file")
        #expect(pack.decision == .allow)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "echo hi > file")
        )
        #expect(composed.decision == .allow)
        guard case .filesystem(let action) = composed.analysis else {
            Issue.record("unprobed write must still attach filesystem analysis")
            return
        }
        #expect(action.operationKind == .write)
    }

    @Test func unprobedCatalogWrite_stillDeniesProtectedPath() throws {
        let command = "echo leaked > id_rsa"
        let pack = try runFilesystemPack(command, secrets: .empty)
        #expect(pack.decision == .allow)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("unprobed catalog hit must still deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        #expect(
            composed.analysis.filesystemAction?.primaryTarget?.scope
                == .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh))
        )
    }

    @Test func unprobedMixedUnknownAndProtected_deniesProtectedPath() throws {
        let command = "rm file id_rsa"
        let pack = try runFilesystemPack(command, secrets: .empty)
        #expect(pack.decision == .allow)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record(
                "unprobed unresolved must not mask a catalog hit, got \(composed.decision)"
            )
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        let scopes = composed.analysis.filesystemAction?.targets.map(\.scope) ?? []
        #expect(scopes.contains(.unknown))
        #expect(scopes.contains { $0.protectedMatch != nil })
    }

    @Test func unprobedMixedUncertainAndOutside_deniesOutside() throws {
        let command = "rm file ../outside-file"
        let pack = try runFilesystemPack(command)
        #expect(pack.decision == .allow)
        let analysis = analyzeFilesystem(
            ShellCommand(rawValue: command),
            context: FilesystemAnalysisContext(
                workingDirectory: WorkingDirectory(validating: "/repo"),
                repositoryRoot: RepositoryRoot(validating: "/repo"),
                facts: [
                    FilesystemPathFact(
                        apparent: "file",
                        canonical: "/repo/file",
                        resolution: .uncertain
                    ),
                ]
            )
        )
        let composed = applyFilesystemSemantics(
            pack: pack,
            analysis: analysis,
            command: ShellCommand(rawValue: command),
            filesystemWorld: .unprobed
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record(
                "unprobed unresolved must not mask out-of-repo, got \(composed.decision)"
            )
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func evaluateDoor_defaultUnprobed_packAllowWrite_staysAllow() throws {
        let result = try runFilesystemDoor("echo hi > file")
        #expect(result.decision == .allow)
        #expect(result.analysis.filesystemAction?.operationKind == .write)
    }

    @Test func evaluateDoor_injectedProbedEmpty_packAllowWrite_isFailClosed() throws {
        let result = try runFilesystemDoor("echo hi > file") { _ in
            .probed(.empty)
        }
        guard case .deny(let deny) = result.decision else {
            Issue.record(
                "injected probed empty must fail-closed at the door, got \(result.decision)"
            )
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID)
    }

    @Test func analysisContext_legacyProbeKey_isIgnoredOnDecode() throws {
        let missing = Data(#"{"facts":[],"probe":"probed"}"#.utf8)
        let decoded = try JSONDecoder().decode(FilesystemAnalysisContext.self, from: missing)
        #expect(decoded.workingDirectory == nil)
        #expect(decoded.facts.isEmpty)

        let data = try JSONEncoder().encode(FilesystemAnalysisContext.empty)
        let roundTrip = try JSONDecoder().decode(FilesystemAnalysisContext.self, from: data)
        #expect(roundTrip.workingDirectory == nil)
        #expect(roundTrip.repositoryRoot == nil)
        #expect(roundTrip.homeDirectory == nil)
        #expect(roundTrip.facts.isEmpty)
        let encoded = try #require(String(data: data, encoding: .utf8))
        #expect(encoded.contains("probe") == false)
    }

    @Test func generatedDelete_staysAllowUnderDefaultPolicy() throws {
        let pack = try runFilesystemPack("rm .build/artifact")
        #expect(pack.decision == .allow)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "rm .build/artifact"),
            filesystemWorld: repo
        )
        #expect(composed.decision == .allow)
        guard case .filesystem(let action) = composed.analysis else {
            Issue.record("expected filesystem analysis")
            return
        }
        #expect(action.resources.resourceKind == .generatedOutput)
    }

    @Test func rmRf_keepsPackDeny() throws {
        let pack = try runFilesystemPack("rm -rf Sources")
        guard case .deny(let packDeny) = pack.decision else {
            Issue.record("sample pack must deny rm -rf")
            return
        }
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "rm -rf Sources"),
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("composed must keep pack deny")
            return
        }
        #expect(deny.ruleID == packDeny.ruleID)
        guard case .filesystem(let action) = composed.analysis else {
            Issue.record("expected filesystem analysis")
            return
        }
        #expect(action.resources.resourceKind == .sourceCode)
    }

    @Test func unknownSyntax_neverBecomesMorePermissive() throws {
        let command = "rm --weird-flag -rf /"
        #expect(analyzeFilesystem(ShellCommand(rawValue: command)) == .unknown)
        let packDeny = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreFilesystem, pattern: "rm-rf-general"),
                    reason: "rm -rf is destructive"
                ),
                matched: nil
            ),
            matchingView: MatchingView(command)
        )
        let composedDeny = applyFilesystemSemantics(
            pack: packDeny,
            command: ShellCommand(rawValue: command)
        )
        #expect(composedDeny.decision == packDeny.decision)
        #expect(composedDeny.analysis == .unknown)

        let echo = try runFilesystemPack("echo hello")
        let composedEcho = applyFilesystemSemantics(
            pack: echo,
            command: ShellCommand(rawValue: "echo hello")
        )
        #expect(composedEcho.decision == echo.decision)
        #expect(composedEcho.analysis == .unknown)
    }

    @Test func protectedSymlink_isDeniedBySemanticsWhenPacksAllow() throws {
        let command = "rm link"
        let pack = try runFilesystemPack(command)
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
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: context
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("protected symlink delete must deny")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        guard case .filesystem(let action) = composed.analysis else {
            Issue.record("expected filesystem analysis")
            return
        }
        #expect(
            action.primaryTarget?.scope
                == .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh))
        )
        #expect(action.primaryTarget?.protectedMatch?.pattern == "id-rsa")
    }

    @Test func dollarHomeWrite_isDeniedAsProtectedPath() throws {
        let command = "echo leaked > $HOME/.ssh/authorized_keys"
        let pack = try runFilesystemPack(command, secrets: .empty)
        #expect(pack.decision == .allow)
        let context = FilesystemAnalysisWorld.probed(
            FilesystemAnalysisContext(
                workingDirectory: WorkingDirectory(validating: "/repo"),
                repositoryRoot: RepositoryRoot(validating: "/repo"),
                homeDirectory: HomePath(validating: "/isolated-home")
            )
        )
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: context
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("HOME-aliased write must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        #expect(
            composed.analysis.filesystemAction?.primaryTarget?.scope
                == .protectedPath(SecretPathMatch(pattern: "home-ssh", category: .ssh))
        )
        #expect(composed.analysis.filesystemAction?.explainCategory == "ssh")
        #expect(composed.analysis.filesystemAction?.explainCatalogRule == "core.secrets/home-ssh")
    }

    @Test func coreFilesystemDisabled_doesNotAddSemanticDeny() {
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
        let composed = applyFilesystemSemantics(
            pack: EvaluationResult(
                outcome: .plain,
                matchingView: MatchingView("rm link")
            ),
            command: ShellCommand(rawValue: "rm link"),
            filesystemWorld: context,
            enabledPacks: []
        )
        #expect(composed.decision == .allow)
        guard case .filesystem(let action) = composed.analysis else {
            Issue.record("analysis still attaches when packs are off")
            return
        }
        #expect(
            action.primaryTarget?.scope
                == .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh))
        )
    }

    @Test func packIndeterminate_isNotLifted() {
        let pack = EvaluationResult(
            outcome: .indeterminate(.corePacksUnavailable),
            matchingView: MatchingView("rm -rf Sources")
        )
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "rm -rf Sources"),
            filesystemWorld: repo
        )
        #expect(composed.decision == .indeterminate(.corePacksUnavailable))
        guard case .filesystem(let action) = composed.analysis else {
            Issue.record("analysis may still attach")
            return
        }
        #expect(action.resources.resourceKind == .sourceCode)
    }

    @Test func typedAsk_inRepoRm_isMandatoryHuman() throws {
        let pack = try runFilesystemPack("rm file.swift")
        #expect(pack.decision == .allow)
        let rule = TypedRule(
            id: RuleID(pack: .coreFilesystem, pattern: "ask-rm"),
            predicate: .filesystemDelete(recursive: nil, force: nil),
            verdict: .ask,
            origin: .machine
        )
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "rm file.swift"),
            filesystemWorld: repo,
            policy: EffectiveActionPolicy(rules: [rule])
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("typed ask must require a human, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == rule.id)
        #expect(composed.boundReview == .mandatoryHuman(deny))
    }

    @Test func gitAnalysis_isNotClobbered() {
        let pack = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git checkout -b feature"),
            analysis: .git(.createBranch(name: "feature", startPoint: nil, force: false))
        )
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "rm Sources/Foo.swift"),
            filesystemWorld: repo
        )
        #expect(composed.analysis == pack.analysis)
    }

    @Test func gitClaim_redirectOutsideRepoDenies() {
        let command = ShellCommand(rawValue: "git stash list > ../outside-file")
        let pack = EvaluationResult(
            outcome: .plain,
            matchingView: Normalize.matchingView(of: command),
            analysis: .git(.stash(verb: .list))
        )
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: command,
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("redirect outside the repo must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func gitClaim_redirectInsideRepoLeavesPackUntouched() {
        for raw in ["git stash list > Sources/log.txt", "git stash list"] {
            let command = ShellCommand(rawValue: raw)
            let pack = EvaluationResult(
                outcome: .plain,
                matchingView: Normalize.matchingView(of: command),
                analysis: .git(.stash(verb: .list))
            )
            let composed = applyFilesystemSemantics(
                pack: pack,
                command: command,
                filesystemWorld: repo
            )
            #expect(composed.decision == .allow)
            #expect(composed.analysis == pack.analysis)
        }
    }

    @Test func gitClaim_packFloorStillWinsFirst() {
        let command = ShellCommand(rawValue: "git stash list > ../outside-file")
        let packDeny = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreFilesystem, pattern: "pack-rule"),
                    reason: "pack denied first"
                ),
                matched: nil
            ),
            matchingView: Normalize.matchingView(of: command),
            analysis: .git(.stash(verb: .list))
        )
        let composed = applyFilesystemSemantics(
            pack: packDeny,
            command: command,
            filesystemWorld: repo
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("pack deny must stand, got \(composed.decision)")
            return
        }
        // The floor wins: the pack's own reason survives, not the redirect's.
        #expect(deny.reason == "pack denied first")
    }
}

private struct FilesystemSampleWorld {
    let packs: [PackSnapshot]
    let engine: ICUPatternEngine
    let compiled: CompiledPacks<ICUCompiledPattern>
}

private func filesystemSampleWorld() throws -> FilesystemSampleWorld {
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
    return FilesystemSampleWorld(packs: packs, engine: engine, compiled: compiled)
}

private func runFilesystemPack(
    _ command: String,
    secrets: SecretPathCatalog = .dayOne
) throws -> EvaluationResult {
    let world = try filesystemSampleWorld()
    var budget = PatternBudget()
    // The pack pass as the semantic door runs it: the unresolved-invocation
    // ask is the door's last step, so semantic denies still apply here.
    return evaluateGated(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: world.packs,
        secretPaths: SecretPathDecider(catalog: secrets),
        engine: world.engine,
        compiled: world.compiled,
        patternBudget: &budget,
        rvdPIDs: { nil },
        floorUnresolved: false
    )
}

private func runFilesystemDoor(
    _ command: String,
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisWorld = { _ in .unprobed }
) throws -> EvaluationResult {
    let world = try filesystemSampleWorld()
    return evaluateWithSemantics(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: world.packs,
        engine: world.engine,
        compiled: world.compiled,
        filesystemProbe: filesystemProbe
    )
}

/// rv's wiring (`RVWiringPaths`) is a protected path for shell writes even
/// inside a repository rooted at `$HOME`, where the outside-repo boundary
/// does not apply. Reads are untouched.
@Suite("ApplyFilesystemSemantics: rv wiring")
struct ApplyFilesystemWiringTests {
    private let homeRepo = FilesystemAnalysisWorld.probed(
        FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/Users/me"),
            repositoryRoot: RepositoryRoot(validating: "/Users/me"),
            homeDirectory: HomePath(validating: "/Users/me")
        )
    )

    private func composed(_ command: String) throws -> EvaluationResult {
        applyFilesystemSemantics(
            pack: try runFilesystemPack(command),
            command: ShellCommand(rawValue: command),
            filesystemWorld: homeRepo
        )
    }

    @Test("writes to wiring deny as protected paths", arguments: [
        "echo '{}' > .claude/settings.json",
        "echo x > ~/.local/bin/rvd",
        "touch Library/LaunchAgents/dev.rv.evaluate.plist",
    ])
    func wiringWriteDenies(command: String) throws {
        let result = try composed(command)
        guard case .deny(let deny) = result.decision else {
            Issue.record("\(command) must deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID, "\(command)")
    }

    @Test("ordinary home-repo writes stay allowed")
    func ordinaryWriteAllowed() throws {
        #expect(try composed("echo hi > notes.txt").decision == .allow)
    }

    private func isProtectedDeny(_ result: EvaluationResult) -> Bool {
        if case .deny(let deny) = result.decision { return deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID }
        return false
    }

    @Test("a hard link whose source is wiring or a secret is a write to the source", arguments: [
        "ln ~/.claude/settings.json evil.json",
        "ln .claude/settings.json evil.json",
        "ln -f .local/bin/rvd x",
        "ln ~/.ssh/id_ed25519 key",
        "ln -t links .claude/settings.json",
    ])
    func hardLinkSourceDenies(command: String) throws {
        guard case .deny = try composed(command).decision else {
            Issue.record("\(command) must deny")
            return
        }
    }

    @Test("moving, deleting or chmod-ing an ancestor of wiring denies", arguments: [
        "mv .claude claude-old",
        "mv ~/.claude /tmp/x",
        "rm -r ~/.local/bin",
        "rm -r .local",
        "mv Library/LaunchAgents la",
        "rm -r .config/systemd/user",
        "rm -r .config",
        "chmod 000 .claude",
        "chmod -R a-r .codex",
    ])
    func ancestorMutationDenies(command: String) throws {
        #expect(isProtectedDeny(try composed(command)), "\(command)")
    }

    @Test("project and local host settings files are protected", arguments: [
        "echo '{}' > src/app/.claude/settings.json",
        "cp x src/app/.claude/settings.local.json",
        "echo x > src/app/.codex/config.toml",
        "tee src/app/.cursor/hooks.json < x",
        "echo x > src/app/.gemini/settings.json",
        "echo x > .claude/settings.local.json",
    ])
    func hostSettingsDeny(command: String) throws {
        #expect(isProtectedDeny(try composed(command)), "\(command)")
    }

    @Test("ordinary links, moves, deletes and host-dir files stay allowed", arguments: [
        "rm notes.txt",
        "rmdir src/empty",
        "mv notes.txt notes2.txt",
        "echo x > src/app/.claude/commands/foo.md",
        "ln -s notes.txt link.txt",
        "ln notes.txt notes-link.txt",
        "touch .claude/CLAUDE.md",
    ])
    func ordinaryAllowed(command: String) throws {
        #expect(try composed(command).decision == .allow, "\(command)")
    }

    @Test("~user expands through the user database; an unknown user is outside the repo")
    func tildeUser() throws {
        let user = NSUserName()
        let home = try #require(FileManager.default.homeDirectory(forUser: user)).path
        let world = FilesystemAnalysisWorld.probed(
            FilesystemAnalysisContext(
                workingDirectory: WorkingDirectory(validating: home + "/src"),
                repositoryRoot: RepositoryRoot(validating: home),
                homeDirectory: HomePath(validating: home)
            )
        )
        func run(_ command: String) throws -> EvaluationResult {
            applyFilesystemSemantics(
                pack: try runFilesystemPack(command), command: ShellCommand(rawValue: command), filesystemWorld: world
            )
        }
        #expect(isProtectedDeny(try run("echo x > ~\(user)/.claude/settings.json")))
        #expect(try run("echo x > ~\(user)/notes.txt").decision == .allow)
        guard case .deny = try run("echo x > ~no-such-user-rv-test/notes.txt").decision else {
            Issue.record("~unknown must not classify inside the repository")
            return
        }
    }
}

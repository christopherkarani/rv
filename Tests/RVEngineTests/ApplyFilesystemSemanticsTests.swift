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
                homeDirectory: "/isolated-home"
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
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: world.packs,
        secrets: secrets,
        engine: world.engine,
        compiled: world.compiled
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

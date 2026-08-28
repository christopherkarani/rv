import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplyFilesystemSemantics")
struct ApplyFilesystemSemanticsTests {
    private let repo = FilesystemAnalysisContext(
        workingDirectory: WorkingDirectory(validating: "/repo"),
        repositoryRoot: RepositoryRoot(validating: "/repo")
    )

    @Test func generatedDelete_staysAllowUnderDefaultPolicy() throws {
        let pack = try runFilesystemPack("rm .build/artifact")
        #expect(pack.decision == .allow)
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "rm .build/artifact"),
            context: repo
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
            context: repo
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
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            context: context
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
        #expect(action.primaryTarget?.scope == .protectedPath)
    }

    @Test func coreFilesystemDisabled_doesNotAddSemanticDeny() {
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
        let composed = applyFilesystemSemantics(
            pack: EvaluationResult(
                outcome: .plain,
                matchingView: MatchingView("rm link")
            ),
            command: ShellCommand(rawValue: "rm link"),
            context: context,
            enabledPacks: []
        )
        #expect(composed.decision == .allow)
        guard case .filesystem(let action) = composed.analysis else {
            Issue.record("analysis still attaches when packs are off")
            return
        }
        #expect(action.primaryTarget?.scope == .protectedPath)
    }

    @Test func packIndeterminate_isNotLifted() {
        let pack = EvaluationResult(
            outcome: .indeterminate(.corePacksUnavailable),
            matchingView: MatchingView("rm -rf Sources")
        )
        let composed = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "rm -rf Sources"),
            context: repo
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
            context: repo
        )
        #expect(composed.analysis == pack.analysis)
    }
}

private func runFilesystemPack(_ command: String) throws -> EvaluationResult {
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

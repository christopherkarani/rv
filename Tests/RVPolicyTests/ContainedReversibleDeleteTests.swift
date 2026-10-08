import Testing
import Foundation
import RVDomain
@testable import RVPolicy

@Suite("ContainedReversibleDelete")
struct ContainedReversibleDeleteTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let cwd = WorkingDirectory(validating: "/repo")!
    private let view = MatchingView("rm -rf .build")

    private func rmDeny(
        pattern: String = "rm-rf-general",
        analysis: SemanticAnalysis
    ) -> EvaluationResult {
        EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreFilesystem, pattern: pattern),
                    reason: "rm -rf is destructive and requires human approval"
                ),
                matched: nil
            ),
            matchingView: view,
            analysis: analysis
        )
    }

    private func generatedTarget(
        apparent: String = ".build",
        scope: FilesystemScope = .insideRepository,
        kind: FilesystemResourceKind = .generatedOutput,
        resolution: FilesystemResolution = .lexical
    ) -> FilesystemTarget {
        FilesystemTarget(
            apparent: apparent,
            canonical: "/repo/.build",
            scope: scope,
            kind: kind,
            resolution: resolution
        )
    }

    private func deleteAnalysis(
        _ targets: [FilesystemTarget],
        recursive: Bool = true,
        force: Bool = true
    ) -> SemanticAnalysis {
        .filesystem(.delete(targets: targets, recursive: recursive, force: force))
    }

    @Test func balanced_allowsInRepoGeneratedDelete() {
        let result = rmDeny(analysis: deleteAnalysis([generatedTarget()]))
        #expect(ContainedReversibleDelete.permits(result))
        let decision = PolicyGate.decision(
            for: result, cwd: cwd, allowlist: .empty, grant: .none, now: now,
            safety: .normal
        )
        #expect(decision.override == .containedReversible)
        #expect(decision.result.decision == .allow)
    }

    @Test func strict_deniesInRepoGeneratedDelete() {
        let result = rmDeny(analysis: deleteAnalysis([generatedTarget()]))
        for safety in [SafetyLevel.strict] {
            let decision = PolicyGate.decision(
                for: result, cwd: cwd, allowlist: .empty, grant: .none, now: now,
                safety: safety
            )
            #expect(decision.override == .none)
            #expect(decision.result.decision == .deny(
                Deny(
                    ruleID: RuleID(pack: .coreFilesystem, pattern: "rm-rf-general"),
                    reason: "rm -rf is destructive and requires human approval"
                )
            ))
        }
    }

    @Test func defaultSafety_isStrict() {
        // Callers opt into the balanced allowance explicitly.
        let result = rmDeny(analysis: deleteAnalysis([generatedTarget()]))
        let decision = PolicyGate.decision(
            for: result, cwd: cwd, allowlist: .empty, grant: .none, now: now
        )
        #expect(decision.override == .none)
    }

    @Test func sourceTarget_denies() {
        let source = generatedTarget(apparent: "src/a.swift", kind: .sourceCode)
        #expect(ContainedReversibleDelete.permits(rmDeny(analysis: deleteAnalysis([source]))) == false)
    }

    @Test func unknownKind_denies() {
        let unknown = generatedTarget(apparent: "mystery", kind: .unknown)
        #expect(ContainedReversibleDelete.permits(rmDeny(analysis: deleteAnalysis([unknown]))) == false)
    }

    @Test func mixedGeneratedAndSource_denies() {
        let source = generatedTarget(apparent: "src", kind: .sourceCode)
        let result = rmDeny(analysis: deleteAnalysis([generatedTarget(), source]))
        #expect(ContainedReversibleDelete.permits(result) == false)
    }

    @Test func outsideRepository_denies() {
        let outside = generatedTarget(scope: .outsideRepository)
        #expect(ContainedReversibleDelete.permits(rmDeny(analysis: deleteAnalysis([outside]))) == false)
    }

    @Test func unknownScope_denies() {
        let unknown = generatedTarget(scope: .unknown)
        #expect(ContainedReversibleDelete.permits(rmDeny(analysis: deleteAnalysis([unknown]))) == false)
    }

    @Test func uncertainResolution_denies() {
        let uncertain = generatedTarget(resolution: .uncertain)
        #expect(
            ContainedReversibleDelete.permits(rmDeny(analysis: deleteAnalysis([uncertain]))) == false
        )
    }

    @Test func globApparent_denies() {
        for apparent in ["build/*", "build/*/", "build/a?.o", "build/[ab]", "build/{a,b}"] {
            let target = generatedTarget(apparent: apparent)
            #expect(
                ContainedReversibleDelete.permits(rmDeny(analysis: deleteAnalysis([target]))) == false,
                "apparent \(apparent) must not override"
            )
        }
    }

    @Test func wrappedDelete_denies() {
        let wrapped = deleteAnalysis([generatedTarget()]).wrapping([.sudo])
        #expect(ContainedReversibleDelete.permits(rmDeny(analysis: wrapped)) == false)
        let shWrapped = deleteAnalysis([generatedTarget()]).wrapping([.bash])
        #expect(ContainedReversibleDelete.permits(rmDeny(analysis: shWrapped)) == false)
    }

    @Test func nonForceOrNonRecursive_denies() {
        #expect(
            ContainedReversibleDelete.permits(
                rmDeny(analysis: deleteAnalysis([generatedTarget()], force: false))
            ) == false
        )
        #expect(
            ContainedReversibleDelete.permits(
                rmDeny(analysis: deleteAnalysis([generatedTarget()], recursive: false))
            ) == false
        )
    }

    @Test func unknownAnalysis_denies() {
        #expect(ContainedReversibleDelete.permits(rmDeny(analysis: .unknown)) == false)
        #expect(ContainedReversibleDelete.permits(rmDeny(analysis: .unwrapLimited)) == false)
    }

    @Test func nonRmPatterns_neverOverride() {
        for pattern in [
            "rm-rf-root-home", "rm-glob-home", "find-delete-general",
            "unlink-general", "redirect-truncate-dynamic-path",
        ] {
            let result = rmDeny(pattern: pattern, analysis: deleteAnalysis([generatedTarget()]))
            #expect(
                ContainedReversibleDelete.permits(result) == false,
                "pattern \(pattern) must never override"
            )
        }
    }

    @Test func semanticHardBind_neverOverrides() {
        var result = rmDeny(analysis: deleteAnalysis([generatedTarget()]))
        result.boundReview = .deny(ActionPolicyEngine.Builtin.outsideRepository)
        #expect(ContainedReversibleDelete.permits(result) == false)
    }

    @Test func userGrant_beatsContainedOverride() {
        let result = rmDeny(analysis: deleteAnalysis([generatedTarget()]))
        let decision = PolicyGate.decision(
            for: result, cwd: cwd, allowlist: .empty, grant: .pending, now: now,
            safety: .normal
        )
        #expect(decision.override == .allowOnce)
    }
}

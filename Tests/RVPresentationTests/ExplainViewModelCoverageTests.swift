import Testing
import RVDomain
@testable import RVPresentation

private let status = ShellCommand(rawValue: "git status")
private let resetHard = ShellCommand(rawValue: "git reset --hard")

@Test func explainViewModel_quickRejectedIsAllowWithoutNext() {
    let vm = explainViewModel(
        from: EvaluationResult(outcome: .quickRejected),
        command: status
    )
    #expect(vm.fact == "allow")
    #expect(vm.nextAction == nil)
    #expect(vm.decisionTone == .allow)
    #expect(vm.semantic == nil)
    #expect(vm.steps.contains(.quickReject(.skipped)))
}

@Test func explainViewModel_unknownWrappersBecomeSemantic() {
    let vm = explainViewModel(
        from: EvaluationResult(
            outcome: .plain,
            analysis: SemanticAnalysis.unknown.wrapping([.timeout, .bash])
        ),
        command: ShellCommand(rawValue: "timeout 1 bash -c 'true'")
    )
    #expect(vm.semantic?.action == "unknown")
    #expect(vm.semantic?.scope == "wrapper")
    #expect(vm.semantic?.wrappers == ["timeout", "bash"])
}

@Test func explainSemantic_wrapperCaseIsPeeledByInnermost() {
    let wrappedUnknown = SemanticAnalysis.wrapper(.env, inner: .unknown)
    #expect(explainSemantic(from: wrappedUnknown)?.action == "unknown")
    #expect(explainSemantic(from: .unknown) == nil)
}

@Test func explainViewModel_gitPushExposesRemoteAndRef() {
    let vm = explainViewModel(
        from: EvaluationResult(
            outcome: .plain,
            analysis: .git(.push(remote: "origin", refspec: "main", force: .force))
        ),
        command: ShellCommand(rawValue: "git push --force origin main")
    )
    #expect(vm.semantic?.action == "force-push")
    #expect(vm.semantic?.scope == "remote")
    #expect(vm.semantic?.effect == "remote shared-branch mutation")
    #expect(vm.semantic?.remote == "origin")
    #expect(vm.semantic?.ref == "main")
}

@Test func explainViewModel_filesystemUnknownScopeOmitsKind() {
    let vm = explainViewModel(
        from: EvaluationResult(
            outcome: .plain,
            analysis: .filesystem(
                .read(
                    targets: [
                        FilesystemTarget(
                            apparent: "mystery",
                            canonical: "mystery",
                            scope: .unknown,
                            kind: .unknown
                        ),
                    ]
                )
            )
        ),
        command: ShellCommand(rawValue: "cat mystery")
    )
    #expect(vm.semantic?.action == "read")
    #expect(vm.semantic?.scope == "unknown")
    #expect(vm.semantic?.kind == nil)
    #expect(vm.semantic?.category == nil)
}

@Test func explainViewModel_protectedPathExposesCatalog() {
    let match = SecretPathMatch(pattern: "id_ed25519", category: .ssh)
    let vm = explainViewModel(
        from: EvaluationResult(
            outcome: .plain,
            analysis: .filesystem(
                .delete(
                    targets: [
                        FilesystemTarget(
                            apparent: "~/.ssh/id_ed25519",
                            canonical: "/home/u/.ssh/id_ed25519",
                            scope: .protectedPath(match),
                            kind: .unknown
                        ),
                    ],
                    recursive: false,
                    force: false
                )
            )
        ),
        command: ShellCommand(rawValue: "rm ~/.ssh/id_ed25519")
    )
    #expect(vm.semantic?.action == "delete")
    #expect(vm.semantic?.scope == "protected path")
    #expect(vm.semantic?.path == "/home/u/.ssh/id_ed25519")
    #expect(vm.semantic?.kind == nil)
    #expect(vm.semantic?.category == "ssh")
    #expect(vm.semantic?.catalogRule == "core.secrets/id_ed25519")
}

@Test func explainStep_destructiveDisplayWords() {
    let rule = RuleID(pack: .coreFilesystem, pattern: "rm-rf-general")
    #expect(ExplainStep.destructive(.none).displayOutcome == "none")
    #expect(ExplainStep.destructive(.rule(rule)).displayOutcome == "core.filesystem/rm-rf-general")
}

@Test func testViewModel_quickRejectedIsAllowed() {
    let vm = testViewModel(
        from: EvaluationResult(outcome: .quickRejected),
        command: status,
        columns: 4
    )
    #expect(vm.resultWord == "ALLOWED")
    #expect(vm.resultTone == .allow)
    #expect(vm.columns == 16)
}

@Test func remapMatchSpan_searchHitWithoutInnerTextReturnsNil() {
    #expect(
        remapMatchSpan(
            span: MatchSpan(start: 90, end: 99),
            matchedText: "nope",
            searchText: "rm -rf ./src",
            onto: "rm -rf ./src"
        ) == nil
    )
}

@Test func testViewModel_safeOnlyIsAllowedWithoutPackEssay() {
    let vm = testViewModel(
        from: EvaluationResult(
            outcome: .safeOnly(SafeMatch(packID: .coreGit, patternName: "checkout-new-branch"))
        ),
        command: status
    )
    #expect(vm.resultWord == "ALLOWED")
    #expect(vm.deny == nil)
    #expect(vm.packDisplay == nil)
    #expect(vm.explanation == nil)
}

@Test func remapMatchSpan_emptySearchOnEmptyCommandCannotKeepSpan() {
    #expect(
        remapMatchSpan(
            span: MatchSpan(start: 0, end: 1),
            matchedText: "x",
            searchText: "",
            onto: ""
        ) == nil
    )
}

@Test func remapMatchSpan_searchMissFallsBackAndEmptySearchDrops() {
    #expect(
        remapMatchSpan(
            span: MatchSpan(start: 0, end: 2),
            matchedText: "rm",
            searchText: "",
            onto: "echo rm"
        ) == MatchSpan(start: 5, end: 7)
    )
    #expect(
        remapMatchSpan(
            span: MatchSpan(start: 90, end: 99),
            matchedText: "rm -rf",
            searchText: "rm -rf ./src",
            onto: "rm -rf ./src"
        ) == MatchSpan(start: 0, end: 6)
    )
    #expect(
        remapMatchSpan(
            span: MatchSpan(start: 0, end: 16),
            matchedText: nil,
            searchText: "git reset --hard",
            onto: "git reset --hard"
        ) == MatchSpan(start: 0, end: 16)
    )
}

@Test func explanationLines_keepsBrokenMarkupAndDropsBlankBullets() {
    #expect(explanationLines(from: "See [docs") == ["See [docs"])
    #expect(explanationLines(from: "See [docs] later") == ["See [docs] later"])
    #expect(explanationLines(from: "See [docs](https://example.com") == ["See [docs](https://example.com"])
    #expect(explanationLines(from: "See [docs]()") == ["See docs"])
    #expect(explanationLines(from: "Look ![alt]()") == ["Look alt"])
    #expect(explanationLines(from: "Intro\n\n\nTail\n") == ["Intro", "", "Tail"])
    #expect(explanationLines(from: "\\ - ") == [])
}

@Test func factSentence_stripsPeriodWithoutFollowingSentence() {
    #expect(factSentence(from: "  blocked.  ") == "blocked")
    #expect(factSentence(from: "no-stop") == "no-stop")
}

@Test func suggestionKinds_haveStableTitles() {
    #expect(SuggestionKind.previewFirst.title == "Preview first")
    #expect(SuggestionKind.saferAlternative.title == "Safer alternative")
    #expect(SuggestionKind.workflowFix.title == "Workflow fix")
    #expect(SuggestionKind.documentation.title == "Documentation")
    #expect(suggestions(for: RuleID(pack: .coreGit, pattern: "unknown-rule")).isEmpty)
}

import Testing
import RVDomain
@testable import RVPresentation

private let resetHard = ShellCommand(rawValue: "git reset --hard")
private let stashDrop = ShellCommand(rawValue: "git stash drop")
private let status = ShellCommand(rawValue: "git status")

private func denyResult(
    pack: String = "core.git",
    pattern: String = "reset-hard",
    reason: String = "git reset --hard destroys uncommitted changes. Use 'git stash' first."
) -> EvaluationResult {
    let rule = RuleID(pack: PackID(rawValue: pack), pattern: pattern)
    return EvaluationResult(
        decision: .deny(Deny(ruleID: rule, reason: reason)),
        matched: RuleMatch(
            ruleID: rule,
            packID: rule.pack,
            patternName: pattern,
            severity: .critical,
            reason: reason
        )
    )
}

private func mediumAllow() -> EvaluationResult {
    let rule = RuleID(pack: .coreGit, pattern: "stash-drop")
    return EvaluationResult(
        decision: .allow,
        matched: RuleMatch(
            ruleID: rule,
            packID: .coreGit,
            patternName: "stash-drop",
            severity: .medium,
            reason: "git stash drop deletes a single stash"
        )
    )
}

@Test func denyViewModel_nilOnAllowIncludingMedium() {
    let allow = EvaluationResult(decision: .allow)
    #expect(denyViewModel(from: allow, command: status) == nil)
    #expect(denyViewModel(from: mediumAllow(), command: stashDrop) == nil)
}

@Test func denyViewModel_nilOnIndeterminate() {
    let result = EvaluationResult(decision: .indeterminate(.commandTooLarge))
    #expect(denyViewModel(from: result, command: resetHard) == nil)
}

@Test func denyViewModel_factAndNextAction() {
    let vm = denyViewModel(from: denyResult(), command: resetHard)
    #expect(vm != nil)
    #expect(vm?.fact == "git reset --hard destroys uncommitted changes")
    #expect(vm?.nextAction == "run it in Terminal, or rv allow-once")
    #expect(vm?.ruleID.rawValue == "core.git:reset-hard")
    #expect(displayRuleID(vm!.ruleID) == "core.git/reset-hard")
}

@Test func explainViewModel_allowHasNoNextAction() {
    let vm = explainViewModel(from: EvaluationResult(decision: .allow), command: status)
    #expect(vm.fact == "allow")
    #expect(vm.nextAction == nil)
    #expect(!vm.steps.contains { $0.outcome.contains("μs") || $0.outcome.contains("us") })
    #expect(vm.steps.map(\.name).contains("normalize"))
    #expect(vm.steps.map(\.name).contains("default"))
}

@Test func explainViewModel_denyHasFactNextAndDestructiveStep() {
    let vm = explainViewModel(from: denyResult(), command: resetHard)
    #expect(vm.fact == "git reset --hard destroys uncommitted changes")
    #expect(vm.nextAction == "run it in Terminal, or rv allow-once")
    #expect(vm.steps.contains { $0.name == "destructive" && $0.outcome == "core.git/reset-hard" })
    #expect(!vm.steps.contains { $0.outcome.contains("μs") })
}

@Test func explainViewModel_mediumAllowKeepsMatchAndNoNext() {
    let vm = explainViewModel(from: mediumAllow(), command: stashDrop)
    #expect(vm.fact == "allow")
    #expect(vm.nextAction == nil)
    #expect(vm.ruleID?.rawValue == "core.git:stash-drop")
}

@Test func packsViewModel_dayOneEnabled() {
    let vm = packsViewModel(
        enabled: dayOnePackIDs,
        catalog: [
            (.coreFilesystem, "filesystem"),
            (.coreGit, "git"),
        ]
    )
    #expect(vm.rows.count == 2)
    #expect(vm.rows.allSatisfy { $0.enabled })
    #expect(vm.rows.map(\.id.rawValue) == ["core.filesystem", "core.git"])
}

@Test func doctorViewModel_isStub() {
    let _: DoctorViewModel = DoctorViewModel()
}

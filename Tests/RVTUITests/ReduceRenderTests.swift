import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVTUI

@Test func reduce_upDownQuitWithoutTTY() {
    var state = BrowseState(rows: ["a", "b", "c"], pageSize: 2)
    #expect(state.selected == 0)
    #expect(state.page == 0)

    state = reduce(state, .down)
    #expect(state.selected == 1)
    state = reduce(state, .down)
    #expect(state.selected == 2)
    #expect(state.page == 1)
    state = reduce(state, .down)
    #expect(state.selected == 2)
    state = reduce(state, .up)
    #expect(state.selected == 1)
    state = reduce(state, .quit)
    #expect(state.quit)
    let same = reduce(state, .enter)
    #expect(same.selected == state.selected)
}

@Test func keyMap_isPure() {
    #expect(mapKey("j") == .down)
    #expect(mapKey("k") == .up)
    #expect(mapKey("\u{001B}[A") == .up)
    #expect(mapKey("\u{001B}[B") == .down)
    #expect(mapKey("q") == .quit)
    #expect(mapKey("\u{001B}") == .quit)
    #expect(mapKey("\r") == .enter)
    #expect(mapKey("x") == .noop)
}

@Test func render_colorOff_hasNoEscape() {
    let state = BrowseState(rows: ["one", "two"], selected: 1)
    let lines = render(state, palette: colorOffPalette)
    #expect(lines.count == 2)
    #expect(lines[1].hasPrefix(">"))
    #expect(lines.allSatisfy { !$0.contains("\u{001B}") })
}

@Test func denyRenderer_colorOff_hasNoEscape() {
    let vm = denyViewModel(
        from: EvaluationResult(
            decision: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
                )
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let lines = DenyRenderer().render(vm!, palette: colorOffPalette)
    #expect(lines.allSatisfy { !$0.contains("\u{001B}") })
    #expect(lines.contains { $0.contains("blocked") })
}

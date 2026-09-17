import Foundation
import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVTUI

private let resetHardRule = RuleID(pack: .coreGit, pattern: "reset-hard")

private func sampleModel(showsCommand: Bool = false) -> ScanViewModel {
    ScanViewModel(
        rows: [
            scanFindingRow(
                host: .claude,
                sessionID: "sess-1",
                sourcePath: "/tmp/fixture/session.jsonl",
                ruleID: resetHardRule,
                packID: .coreGit,
                matchingView: MatchingView("git reset --hard"),
                count: 3,
                showsCommand: showsCommand
            ),
            scanFindingRow(
                host: .pi,
                sourcePath: "/tmp/pi/session.jsonl",
                ruleID: RuleID(pack: .coreFilesystem, pattern: "rm-rf-general"),
                packID: .coreFilesystem,
                matchingView: MatchingView("rm -rf ./src"),
                showsCommand: showsCommand
            ),
        ],
        warnings: [ScanWarningRow(code: "cap.files", message: "Stopped after 10000 files")],
        filesScanned: 12,
        eventsExtracted: 40,
        setupNudgeRecommended: true,
        showsCommand: showsCommand
    )
}

@Test func scanPrettyRenderer_includesRuleIDAndRedactedCommand() {
    let vm = sampleModel()
    let lines = ScanPrettyRenderer().render(vm, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("core.git:reset-hard"))
    #expect(joined.contains("git …"))
    #expect(joined.contains("rm …"))
    #expect(joined.contains("core.filesystem:rm-rf-general"))
    #expect(joined.contains("×3"))
    #expect(joined.contains("warning cap.files"))
    #expect(joined.contains("12 files scanned, 40 events, 2 findings"))
    #expect(joined.contains("rv setup"))
    #expect(joined.contains("git reset --hard") == false)
    #expect(lines.allSatisfy { $0.contains("\u{001B}") == false })
}

@Test func scanPrettyRenderer_emptyFindings() {
    let vm = ScanViewModel(rows: [], filesScanned: 4, eventsExtracted: 0)
    let lines = ScanPrettyRenderer().render(vm, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("No deny findings."))
    #expect(joined.contains("4 files scanned, 0 events, 0 findings"))
}

@Test func scanBrowseReduce_movesSelectionWithinBounds() {
    let state = ScanBrowseState(model: sampleModel())
    #expect(state.selectedIndex == 0)

    let down = state.applying(.down)
    #expect(down.selectedIndex == 1)

    let downAgain = down.applying(.down)
    #expect(downAgain.selectedIndex == 1)

    let up = downAgain.applying(.up)
    #expect(up.selectedIndex == 0)

    let upAgain = up.applying(.up)
    #expect(upAgain.selectedIndex == 0)
}

@Test func scanBrowseRender_paintsSelectedRowWithoutTTY() {
    var state = ScanBrowseState(model: sampleModel())
    state = state.applying(.down)
    let lines = ScanBrowseRenderer().render(state, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(lines.first == "RV SCAN")
    #expect(joined.contains("› core.filesystem:rm-rf-general  rm …"))
    #expect(joined.contains(" core.git:reset-hard  git … ×3"))
    #expect(joined.contains("Host") && joined.contains("pi"))
    #expect(joined.contains("j/k move"))
    #expect(lines.allSatisfy { $0.contains("\u{001B}") == false })
}

@Test func scanBrowseRender_emptyFindingsStillFrames() {
    let state = ScanBrowseState(model: ScanViewModel(rows: []))
    let lines = ScanBrowseRenderer().render(state, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("No deny findings."))
    #expect(joined.contains("0 files scanned"))
    #expect(lines.allSatisfy { $0.contains("\u{001B}") == false })
}

@Test func scanBrowseReduce_noOpOnEmptyList() {
    let state = ScanBrowseState(model: ScanViewModel(rows: []))
    #expect(state.applying(.down).selectedIndex == 0)
    #expect(state.applying(.up).selectedIndex == 0)
}

@Test func scanBrowseRender_clampsOutOfRangeSelection() {
    let state = ScanBrowseState(model: sampleModel(), selectedIndex: 99)
    let lines = ScanBrowseRenderer().render(state, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(state.selectedIndex == 1)
    #expect(joined.contains("› core.filesystem:rm-rf-general  rm …"))
    #expect(joined.contains(" core.git:reset-hard  git … ×3"))
}

@Test func scanPrettyRenderer_showCommandPrintsFullCommand() {
    let vm = sampleModel(showsCommand: true)
    let joined = ScanPrettyRenderer().render(vm, palette: colorOffPalette).joined(separator: "\n")

    #expect(joined.contains("git reset --hard"))
    #expect(joined.contains("rm -rf ./src"))
}

@Test func scanPrettyRenderer_singleFindingWordAndColor() {
    let vm = ScanViewModel(
        rows: [
            scanFindingRow(
                host: .claude,
                sourcePath: "/tmp/fixture/session.jsonl",
                ruleID: resetHardRule,
                packID: .coreGit,
                matchingView: MatchingView("git reset --hard"),
                showsCommand: false
            ),
        ],
        filesScanned: 1,
        eventsExtracted: 1
    )
    let off = ScanPrettyRenderer().render(vm, palette: colorOffPalette).joined(separator: "\n")
    #expect(off.contains("1 files scanned, 1 events, 1 finding"))
    #expect(off.contains("findings") == false)

    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let painted = ScanPrettyRenderer().render(vm, palette: on)
    #expect(painted.contains { $0.contains(on.deny) })
}

@Test func scanBrowse_helpersAndNoopEventsKeepSelection() {
    let model = sampleModel()
    let state = scanBrowseState(model: model, selectedIndex: -3)
    #expect(state.selectedIndex == 0)
    #expect(scanBrowseReduce(state, .enter).selectedIndex == 0)
    #expect(scanBrowseReduce(state, .quit).selectedIndex == 0)
    #expect(scanBrowseReduce(state, .noop).selectedIndex == 0)
    #expect(scanBrowseRender(state, palette: colorOffPalette).first == "RV SCAN")
}

@Test func scanBrowseRender_singleFindingUsesSingularWord() {
    let vm = ScanViewModel(
        rows: [
            scanFindingRow(
                host: .claude,
                sourcePath: "/tmp/fixture/session.jsonl",
                ruleID: resetHardRule,
                packID: .coreGit,
                matchingView: MatchingView("git reset --hard"),
                showsCommand: false
            ),
        ],
        filesScanned: 1,
        eventsExtracted: 1
    )
    let joined = ScanBrowseRenderer().render(ScanBrowseState(model: vm), palette: colorOffPalette)
        .joined(separator: "\n")
    #expect(joined.contains("1 files scanned, 1 events, 1 finding"))
    #expect(joined.contains("findings") == false)
}

@Test func scanBrowseRender_detailIncludesSessionCountAndColor() {
    let state = ScanBrowseState(model: sampleModel(), selectedIndex: 0)
    let off = ScanBrowseRenderer().render(state, palette: colorOffPalette)
    let joined = off.joined(separator: "\n")
    #expect(joined.contains("Session"))
    #expect(joined.contains("sess-1"))
    #expect(joined.contains("Count"))
    #expect(joined.contains("3"))
    #expect(joined.contains("Some hosts are not wired"))

    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let painted = ScanBrowseRenderer().render(state, palette: on)
    #expect(painted.contains { $0.contains(on.mark) && $0.contains("›") })
    #expect(painted.contains { $0.contains(on.deny) })
}

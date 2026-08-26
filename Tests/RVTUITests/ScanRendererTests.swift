import Foundation
import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVTUI

private let resetHardRule = RuleID(pack: .coreGit, pattern: "reset-hard")

private func sampleModel(showCommand: Bool = false) -> ScanViewModel {
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
                showCommand: showCommand
            ),
            scanFindingRow(
                host: .pi,
                sourcePath: "/tmp/pi/session.jsonl",
                ruleID: RuleID(pack: .coreFilesystem, pattern: "rm-rf-general"),
                packID: .coreFilesystem,
                matchingView: MatchingView("rm -rf ./src"),
                showCommand: showCommand
            ),
        ],
        warnings: [ScanWarningRow(code: "cap.files", message: "Stopped after 10000 files")],
        filesScanned: 12,
        eventsExtracted: 40,
        setupNudgeRecommended: true,
        showCommand: showCommand
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
    let state = scanBrowseState(model: sampleModel())
    #expect(state.selectedIndex == 0)

    let down = scanBrowseReduce(state, .down)
    #expect(down.selectedIndex == 1)

    let downAgain = scanBrowseReduce(down, .down)
    #expect(downAgain.selectedIndex == 1)

    let up = scanBrowseReduce(downAgain, .up)
    #expect(up.selectedIndex == 0)

    let upAgain = scanBrowseReduce(up, .up)
    #expect(upAgain.selectedIndex == 0)
}

@Test func scanBrowseRender_paintsSelectedRowWithoutTTY() {
    var state = scanBrowseState(model: sampleModel())
    state = scanBrowseReduce(state, .down)
    let lines = scanBrowseRender(state, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(lines.first == "RV SCAN")
    #expect(joined.contains("› core.filesystem:rm-rf-general  rm …"))
    #expect(joined.contains(" core.git:reset-hard  git … ×3"))
    #expect(joined.contains("Host") && joined.contains("pi"))
    #expect(joined.contains("j/k move"))
    #expect(lines.allSatisfy { $0.contains("\u{001B}") == false })
}

@Test func scanBrowseRender_emptyFindingsStillFrames() {
    let state = scanBrowseState(model: ScanViewModel(rows: []))
    let lines = scanBrowseRender(state, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("No deny findings."))
    #expect(joined.contains("0 files scanned"))
    #expect(lines.allSatisfy { $0.contains("\u{001B}") == false })
}

@Test func scanBrowseReduce_noOpOnEmptyList() {
    let state = scanBrowseState(model: ScanViewModel(rows: []))
    #expect(scanBrowseReduce(state, .down).selectedIndex == 0)
    #expect(scanBrowseReduce(state, .up).selectedIndex == 0)
}

@Test func scanBrowseRender_clampsOutOfRangeSelection() {
    let state = ScanBrowseState(model: sampleModel(), selectedIndex: 99)
    let lines = scanBrowseRender(state, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(state.selectedIndex == 1)
    #expect(joined.contains("› core.filesystem:rm-rf-general  rm …"))
    #expect(joined.contains(" core.git:reset-hard  git … ×3"))
}

@Test func scanPrettyRenderer_showCommandPrintsFullCommand() {
    let vm = sampleModel(showCommand: true)
    let joined = ScanPrettyRenderer().render(vm, palette: colorOffPalette).joined(separator: "\n")

    #expect(joined.contains("git reset --hard"))
    #expect(joined.contains("rm -rf ./src"))
}

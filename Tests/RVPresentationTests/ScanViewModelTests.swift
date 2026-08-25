import Foundation
import Testing
@testable import RVPresentation
import RVDomain

private let resetHardRule = RuleID(pack: .coreGit, pattern: "reset-hard")

private func sampleFinding(command: String = "git reset --hard", count: Int = 1) -> ScanFinding {
    ScanFinding(
        host: .claude,
        sessionID: "sess-1",
        sourcePath: "/tmp/fixture/session.jsonl",
        occurredAt: Date(timeIntervalSince1970: 1_724_000_000),
        ruleID: resetHardRule,
        packID: .coreGit,
        matchingView: MatchingView(command),
        count: count,
        lastSeen: Date(timeIntervalSince1970: 1_724_100_000)
    )
}

@Test func redactMatchingView_firstTokenAndEllipsis() {
    #expect(redactMatchingView(MatchingView("git reset --hard")) == "git …")
    #expect(redactMatchingView(MatchingView("git")) == "git")
    #expect(redactMatchingView(MatchingView("")) == "[redacted]")
    #expect(redactMatchingView(MatchingView("   ")) == "[redacted]")
}

@Test func scanFindingRow_redactsByDefault() {
    let row = scanFindingRow(from: sampleFinding(), showCommand: false)
    #expect(row.ruleLabel == "core.git:reset-hard")
    #expect(row.commandDisplay == "git …")
    #expect(row.host == .claude)
    #expect(row.count == 1)
}

@Test func scanFindingRow_showCommandUsesMatchingView() {
    let row = scanFindingRow(from: sampleFinding(), showCommand: true)
    #expect(row.commandDisplay == "git reset --hard")
}

@Test func scanViewModel_mapsReportFields() {
    let warning = ScanWarning(code: "cap.files", message: "Stopped after 10000 files")
    let report = ScanReport(
        findings: [sampleFinding(count: 3)],
        warnings: [warning],
        filesScanned: 12,
        eventsExtracted: 40,
        setupNudgeRecommended: true
    )
    let vm = scanViewModel(from: report)
    #expect(vm.rows.count == 1)
    #expect(vm.rows[0].commandDisplay == "git …")
    #expect(vm.rows[0].count == 3)
    #expect(vm.warnings == [warning])
    #expect(vm.filesScanned == 12)
    #expect(vm.eventsExtracted == 40)
    #expect(vm.setupNudgeRecommended)
    #expect(vm.showCommand == false)
}

@Test func scanViewModel_emptyReport() {
    let vm = scanViewModel(from: ScanReport())
    #expect(vm.rows.isEmpty)
    #expect(vm.warnings.isEmpty)
    #expect(vm.filesScanned == 0)
    #expect(vm.eventsExtracted == 0)
    #expect(vm.setupNudgeRecommended == false)
}

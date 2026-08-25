import Foundation
import Testing
@testable import RVDomain

@Test func scanBounds_defaultsMatchREQ016() {
    let bounds = ScanBounds.default
    #expect(bounds.maxDepth == 8)
    #expect(bounds.maxFiles == 10_000)
    #expect(bounds.maxTotalBytes == 268_435_456)
    #expect(bounds.maxFileBytes == 33_554_432)
    #expect(ScanBounds() == bounds)
}

@Test func scanHostID_rawValuesMatchSpec() {
    #expect(ScanHostID.claude.rawValue == "claude")
    #expect(ScanHostID.pi.rawValue == "pi")
    #expect(ScanHostID.grok.rawValue == "grok")
    #expect(ScanHostID.opencode.rawValue == "opencode")
}

@Test func extractedEvent_carriesProvenanceAndCommand() {
    let when = Date(timeIntervalSince1970: 1_724_000_000)
    let event = ExtractedEvent(
        host: .pi,
        sessionID: "s1",
        sourcePath: "/tmp/fixture/session.jsonl",
        occurredAt: when,
        command: ShellCommand(rawValue: "git reset --hard")
    )
    #expect(event.host == .pi)
    #expect(event.sessionID == "s1")
    #expect(event.sourcePath == "/tmp/fixture/session.jsonl")
    #expect(event.occurredAt == when)
    #expect(event.command.rawValue == "git reset --hard")
}

@Test func scanFinding_reusesRuleIDAndPackID() {
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let finding = ScanFinding(
        host: .claude,
        sourcePath: "/tmp/fixture/session.jsonl",
        ruleID: rule,
        packID: .coreGit,
        matchingView: MatchingView("git reset --hard"),
        count: 3
    )
    #expect(finding.ruleID.rawValue == "core.git:reset-hard")
    #expect(finding.packID == .coreGit)
    #expect(finding.count == 3)
    #expect(finding.matchingView.rawValue == "git reset --hard")
}

@Test func scanReport_holdsFindingsAndWarnings() {
    let warning = ScanWarning(code: "cap.files", message: "Stopped after 10000 files")
    let finding = ScanFinding(
        host: .grok,
        sourcePath: "/tmp/a",
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        packID: .coreGit,
        matchingView: MatchingView("git reset --hard")
    )
    let report = ScanReport(
        findings: [finding],
        warnings: [warning],
        filesScanned: 12,
        eventsExtracted: 40,
        setupNudgeRecommended: true
    )
    #expect(report.findings.count == 1)
    #expect(report.warnings == [warning])
    #expect(report.filesScanned == 12)
    #expect(report.eventsExtracted == 40)
    #expect(report.setupNudgeRecommended)
}

@Test func scanTypes_areSendableValueTypes() {
    let bounds: any Sendable = ScanBounds.default
    let host: any Sendable = ScanHostID.opencode
    let event: any Sendable = ExtractedEvent(
        host: .opencode,
        sourcePath: "p",
        command: ShellCommand(rawValue: "true")
    )
    let finding: any Sendable = ScanFinding(
        host: .opencode,
        sourcePath: "p",
        ruleID: RuleID(pack: .coreFilesystem, pattern: "rm-rf"),
        packID: .coreFilesystem,
        matchingView: MatchingView("rm -rf /")
    )
    let warning: any Sendable = ScanWarning(code: "cap.file-size", message: "skipped")
    let report: any Sendable = ScanReport()
    _ = (bounds, host, event, finding, warning, report)
}

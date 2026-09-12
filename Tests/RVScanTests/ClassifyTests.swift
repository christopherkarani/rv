import Foundation
import Testing
import RVDomain
@testable import RVScan

@Test func classify_denyResetHard_emitsFindingWithDayOneRuleID() throws {
    let events = [
        ExtractedEvent(
            host: .claude,
            sessionID: "s1",
            sourcePath: "/tmp/fixture/session.jsonl",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            command: ShellCommand(rawValue: "git reset --hard")
        ),
    ]
    let findings = try ScanClassify().classify(events)

    #expect(findings.count == 1)
    let finding = try #require(findings.first)
    #expect(finding.ruleID.rawValue == "core.git:reset-hard")
    #expect(finding.packID == finding.ruleID.pack)
    #expect(finding.packID == .coreGit)
    #expect(finding.host == .claude)
    #expect(finding.sessionID == "s1")
    #expect(finding.sourcePath == "/tmp/fixture/session.jsonl")
    #expect(finding.count == 1)
    #expect(finding.matchingView.rawValue.contains("git"))
    #expect(finding.matchingView.rawValue.contains("reset"))
}

@Test func classify_semanticOnlyDeny_emitsFinding() throws {
    // Packs allow this (no destructive pattern); the evaluation door's
    // unwrap-limited fail-closed deny must still surface as a finding.
    let events = [
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/fixture/session.jsonl",
            command: ShellCommand(rawValue: #"python -c "mystery(payload)""#)
        ),
    ]
    let findings = try ScanClassify().classify(events)

    let finding = try #require(findings.first)
    #expect(findings.count == 1)
    #expect(finding.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
}

@Test func classify_packAllowWrite_emitsNoFindings() throws {
    let events = [
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/fixture/session.jsonl",
            command: ShellCommand(rawValue: "echo hi > file")
        ),
    ]
    let findings = try ScanClassify().classify(events)
    #expect(findings.isEmpty)
}

@Test func classify_packAllowRm_emitsNoFindings() throws {
    let events = [
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/fixture/session.jsonl",
            command: ShellCommand(rawValue: "rm foo")
        ),
    ]
    let findings = try ScanClassify().classify(events)
    #expect(findings.isEmpty)
}

@Test func classify_allowGitStatus_emitsNoFindings() throws {
    let events = [
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/fixture/session.jsonl",
            command: ShellCommand(rawValue: "git status")
        ),
    ]
    let findings = try ScanClassify().classify(events)
    #expect(findings.isEmpty)
}

@Test func classify_ignoresPolicyShape_stillDeniesResetHard() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-scan-classify-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let grantURL = root.appendingPathComponent("allow-once.jsonl", isDirectory: false)
    let grantBytes = Data("planted-grant-marker\n".utf8)
    try grantBytes.write(to: grantURL, options: .atomic)

    let events = [
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/fixture/session.jsonl",
            command: ShellCommand(rawValue: "git reset --hard")
        ),
    ]
    let findings = try ScanClassify().classify(events)

    #expect(findings.count == 1)
    #expect(findings.first?.ruleID.rawValue == "core.git:reset-hard")
    #expect(try Data(contentsOf: grantURL) == grantBytes)
}

@Test func classify_writesNeitherHistoryNorGrantFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-scan-classify-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let grantURL = root.appendingPathComponent("allow-once.jsonl", isDirectory: false)
    let historyURL = root.appendingPathComponent("history.jsonl", isDirectory: false)
    let grantBytes = Data("untouched-grant\n".utf8)
    try grantBytes.write(to: grantURL, options: .atomic)

    let before = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    )

    _ = try ScanClassify().classify([
        ExtractedEvent(
            host: .pi,
            sourcePath: "/tmp/pi/session.json",
            command: ShellCommand(rawValue: "git reset --hard HEAD~1")
        ),
    ])

    let after = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    )
    #expect(Set(after.map(\.lastPathComponent)) == Set(before.map(\.lastPathComponent)))
    #expect(try Data(contentsOf: grantURL) == grantBytes)
    #expect(FileManager.default.fileExists(atPath: historyURL.path) == false)
}

@Test func classify_sourcesDoNotImportPolicyOrHistory() throws {
    let classifyRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RVScan/Classify", isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(
        at: classifyRoot,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    #expect(files.isEmpty == false)
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("import RVPolicy") == false)
        #expect(text.contains("import RVHistory") == false)
        #expect(text.contains("import RVService") == false)
        #expect(text.contains("FilesystemLiveProbe") == false)
        #expect(text.contains("AllowOnce") == false)
        #expect(text.contains("GatedEvaluate") == false)
        #expect(text.contains("PolicyGate") == false)
    }
}

@Test func classify_rejectsEnabledPacksThatCannotWarmCore() {
    #expect(throws: ScanClassifyError.packsUnavailable) {
        try ScanClassify(enabledPacks: [PackID(rawValue: "no.such.pack")])
    }
}

@Test func classify_defaultsToDayOnePacks() throws {
    let classify = try ScanClassify()
    #expect(classify.enabledPacks == dayOnePackIDs)
}

@Test func classify_extractedEventDefaultsWorkingDirectoryNil() {
    let event = ExtractedEvent(
        host: .claude,
        sourcePath: "/tmp/fixture/session.jsonl",
        command: ShellCommand(rawValue: "echo hi > file")
    )
    #expect(event.workingDirectory == nil)
}

@Test func classify_nilWorkingDirectory_packAllowWrite_staysUnprobed() throws {
    let events = [
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/fixture/session.jsonl",
            command: ShellCommand(rawValue: "echo hi > file"),
            workingDirectory: nil
        ),
    ]
    let findings = try ScanClassify().classify(events)
    #expect(findings.isEmpty)
}

@Test func classify_workingDirectory_packAllowWrite_isUnresolvedPath() throws {
    let cwd = try #require(WorkingDirectory(validating: "/tmp/rv-scan-ws"))
    let events = [
        ExtractedEvent(
            host: .grok,
            sourcePath: "/tmp/fixture/chat_history.jsonl",
            command: ShellCommand(rawValue: "echo hi > file"),
            workingDirectory: cwd
        ),
    ]
    let findings = try ScanClassify().classify(events)
    let finding = try #require(findings.first)
    #expect(findings.count == 1)
    #expect(finding.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID)
}

@Test func classify_workingDirectory_protectedPathLexicalHit_stillDenies() throws {
    let cwd = try #require(WorkingDirectory(validating: "/tmp/.ssh"))
    let events = [
        ExtractedEvent(
            host: .claude,
            sourcePath: "/tmp/fixture/session.jsonl",
            command: ShellCommand(rawValue: "rm config"),
            workingDirectory: cwd
        ),
    ]
    let findings = try ScanClassify().classify(events)
    let finding = try #require(findings.first)
    #expect(findings.count == 1)
    #expect(finding.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
}

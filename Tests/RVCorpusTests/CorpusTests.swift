import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

struct CorpusCase: Decodable {
    var id: String
    var command: String?
    var expected: String?
    var ruleID: String?
    var reasonContains: String?
    var kind: String?
    var pinned_0_11_0: String?
    var skillClaimed: String?

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case expected
        case ruleID = "rule_id"
        case reasonContains = "reason_contains"
        case kind
        case pinned_0_11_0
        case skillClaimed = "skill_claimed"
    }
}

struct CorpusFile: Decodable {
    var cases: [CorpusCase]
}

private func corpusDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVEngineTests/Fixtures/corpus")
}

private func loadCases(_ name: String) throws -> [CorpusCase] {
    let url = corpusDirectory().appendingPathComponent(name)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(CorpusFile.self, from: data).cases
}

private func evaluateCommand(_ command: String) throws -> EvaluationResult {
    let packs = try PackRegistry.loadDayOne()
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
}

private func assertCase(_ row: CorpusCase) throws {
    guard let command = row.command, let expected = row.expected else { return }
    let result = try evaluateCommand(command)
    switch expected {
    case "deny":
        guard case .deny(let deny) = result.decision else {
            Issue.record("\(row.id): expected deny, got \(String(describing: result.decision))")
            return
        }
        if let ruleID = row.ruleID {
            #expect(deny.ruleID.rawValue == ruleID, "\(row.id)")
        }
        if let needle = row.reasonContains {
            #expect(deny.reason.contains(needle), "\(row.id)")
        }
        #expect(result.matched?.ruleID.rawValue == row.ruleID ?? result.matched?.ruleID.rawValue)
    case "allow":
        #expect(result.decision == .allow, "\(row.id) got \(String(describing: result.decision))")
        if let ruleID = row.ruleID {
            #expect(result.matched?.ruleID.rawValue == ruleID, "\(row.id)")
        }
    case "indeterminate":
        guard case .indeterminate = result.decision else {
            Issue.record("\(row.id): expected indeterminate")
            return
        }
    default:
        Issue.record("\(row.id): unknown expected \(expected)")
    }
}

@Test func corpus_skillTable() throws {
    for row in try loadCases("skill-table.json") {
        try assertCase(row)
    }
}

@Test func corpus_deny() throws {
    for row in try loadCases("deny.json") {
        try assertCase(row)
    }
}

@Test func corpus_nearMiss() throws {
    for row in try loadCases("near-miss.json") {
        try assertCase(row)
    }
}

@Test func corpus_quarantineFollowsPinned() throws {
    let rows = try loadCases("quarantine.json")
    #expect(rows.contains { $0.id == "skill.stale.tmpdir-allow" })
    #expect(rows.contains { $0.id == "skill.stale.stash-drop-block" })
    #expect(rows.contains { $0.id == "skill.counts.34-16" })
    for row in rows where row.kind != "meta" {
        try assertCase(row)
        if let claimed = row.skillClaimed, let pinned = row.pinned_0_11_0, let expected = row.expected {
            #expect(expected == pinned, "\(row.id) must follow pinned, not \(claimed)")
        }
    }
}

@Test func corpus_everyPatternCompilesOnICU() throws {
    let packs = try PackRegistry.loadDayOne()
    let compiled = try CompiledPacks.compile(packs: packs, using: ICUPatternEngine())
    #expect(!compiled.quarantined.contains { $0.pattern == "reset-hard" })
    #expect(!compiled.quarantined.contains { $0.pattern == "fork-bomb" })
    let git = try #require(compiled.packs.first { $0.snapshot.id == .coreGit })
    #expect(git.destructive.contains { $0.rule.name == "reset-hard" })
    let filesystem = try #require(compiled.packs.first { $0.snapshot.id == .coreFilesystem })
    #expect(filesystem.destructive.contains { $0.rule.name == "fork-bomb" })
}

@Test func corpus_everyNonSemanticDestructiveHasTruePositive() throws {
    let semantic = Set([
        "git-alias-semantic-unverified",
        "branch-dynamic-token",
        "sed-exec-unverified",
    ])
    let packs = try PackRegistry.loadDayOne()
    var covered = Set<String>()
    for file in ["skill-table.json", "deny.json"] {
        for row in try loadCases(file) where row.expected == "deny" || row.ruleID != nil {
            if let ruleID = row.ruleID, let parsed = RuleID(rawValue: ruleID) {
                covered.insert(parsed.pattern)
            }
        }
    }
    for pack in packs {
        for rule in pack.destructive where !semantic.contains(rule.name) {
            #expect(covered.contains(rule.name), Comment(rawValue: "\(pack.id.rawValue):\(rule.name)"))
        }
    }
}

@Test func corpus_skillDenyResetHardExists() throws {
    let rows = try loadCases("skill-table.json")
    #expect(rows.contains { $0.id == "skill.deny.reset-hard" })
    let result = try evaluateCommand("git reset --hard")
    guard case .deny(let deny) = result.decision else {
        Issue.record("day-one deny missing")
        return
    }
    #expect(deny.ruleID.rawValue == "core.git:reset-hard")
}

import Foundation
import Testing
import RVDomain
import RVHooks
import RVPresentation
import RVTheme
import RVTUI

private struct CorpusCase: Decodable, Sendable {
    var id: String
    var command: String?
    var expected: String?
    var ruleID: String?
    var reasonContains: String?

    enum CodingKeys: String, CodingKey {
        case id, command, expected
        case ruleID = "rule_id"
        case reasonContains = "reason_contains"
    }
}

private struct CorpusFile: Decodable {
    var cases: [CorpusCase]
}

private func skillTableDenyRows() throws -> [CorpusCase] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVEngineTests/Fixtures/corpus/skill-table.json")
    let file = try JSONDecoder().decode(CorpusFile.self, from: Data(contentsOf: url))
    return file.cases.filter { $0.expected == "deny" }
}

private func cannedReason(containing needle: String?) -> String {
    if let needle, !needle.isEmpty {
        return "\(needle). Continue in Terminal."
    }
    return "blocked. Continue in Terminal."
}

private func cannedDenyResult(command: String, ruleID: RuleID, reason: String) -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(
            Deny(ruleID: ruleID, reason: reason),
            matched: RuleMatch(
                ruleID: ruleID,
                packID: ruleID.pack,
                patternName: ruleID.pattern,
                severity: .critical,
                reason: reason,
                span: MatchSpan(start: 0, end: command.count),
                matchedText: command
            )
        )
    )
}

@Test func skillTableDenies_shareDenyRendererContract() throws {
    let denies = try skillTableDenyRows()
    #expect(denies.isEmpty == false)

    for row in denies {
        let command = try #require(row.command, Comment(rawValue: row.id))
        let ruleID = try #require(
            row.ruleID.flatMap(RuleID.init(rawValue:)),
            Comment(rawValue: row.id)
        )
        let reason = cannedReason(containing: row.reasonContains)
        let shell = ShellCommand(rawValue: command)
        let result = cannedDenyResult(command: command, ruleID: ruleID, reason: reason)

        let vm = try #require(
            denyViewModel(from: result, command: shell),
            Comment(rawValue: row.id)
        )
        #expect(vm.nextAction == denyNextAction, Comment(rawValue: row.id))
        #expect(vm.ruleID == ruleID, Comment(rawValue: row.id))
        #expect(vm.packReason == reason, Comment(rawValue: row.id))
        if let needle = row.reasonContains {
            #expect(vm.fact.contains(needle) == true, Comment(rawValue: row.id))
        }

        let text = hostDenyText(from: result, command: shell)
        #expect(text != nil, Comment(rawValue: row.id))
        #expect(text?.contains("\n") == false, Comment(rawValue: row.id))
        #expect(text?.contains("═") == false, Comment(rawValue: row.id))
        #expect(text?.contains("┌") == false, Comment(rawValue: row.id))
        #expect(text?.contains(displayRuleID(ruleID)) == true, Comment(rawValue: row.id))
        #expect(text?.contains("rv allow-once") == true, Comment(rawValue: row.id))

        let test = testViewModel(from: result, command: shell)
        #expect(test.deny == vm, Comment(rawValue: row.id))
        let lines = TestRenderer().render(test, palette: colorOffPalette)
        #expect(
            lines.contains { $0.contains("Matched: \(ruleID.rawValue)") },
            Comment(rawValue: row.id)
        )
        #expect(lines.contains { $0 == "Result: BLOCKED" }, Comment(rawValue: row.id))
        #expect(
            lines.contains { $0.hasPrefix("Pack: \(ruleID.pack.rawValue)") },
            Comment(rawValue: row.id)
        )
        #expect(lines.allSatisfy { $0.count <= 80 || $0.contains(command) }, Comment(rawValue: row.id))
    }
}

@Test func prettyTest_prefersDenyViewModelOverStaleFlatFields() throws {
    let command = ShellCommand(rawValue: "git reset --hard")
    let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
    let reason = "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    let result = cannedDenyResult(command: command.rawValue, ruleID: ruleID, reason: reason)
    var model = testViewModel(from: result, command: command)
    try #require(model.deny != nil)
    model.packDisplay = "stale.pack"
    model.patternName = "stale-pattern"
    model.reason = "stale reason"

    let lines = TestRenderer().render(model, palette: colorOffPalette)
    #expect(lines.contains { $0.hasPrefix("Pack: core.git") })
    #expect(lines.contains { $0.hasPrefix("Pattern: reset-hard") })
    #expect(lines.contains { $0.hasPrefix("Reason: \(reason)") })
    #expect(lines.contains { $0.contains("stale") } == false)
}

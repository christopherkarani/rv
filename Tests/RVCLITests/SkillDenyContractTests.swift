import Foundation
import Testing
import RVDomain
import RVPresentation
import RVTheme
import RVTUI
@testable import RVCLI

private struct CorpusCase: Decodable {
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

@Test func skillTableDenies_shareDenyRendererContract() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVEngineTests/Fixtures/corpus/skill-table.json")
    let file = try JSONDecoder().decode(CorpusFile.self, from: Data(contentsOf: url))
    let denies = file.cases.filter { $0.expected == "deny" }
    #expect(!denies.isEmpty)

    for row in denies {
        guard let command = row.command else { continue }
        let result = CommandRun.evaluateCommand(command)
        guard case .deny(let deny) = result.decision else {
            Issue.record("\(row.id): expected deny")
            continue
        }
        if let ruleID = row.ruleID {
            #expect(deny.ruleID.rawValue == ruleID, Comment(rawValue: row.id))
        }
        let vm = denyViewModel(from: result, command: ShellCommand(rawValue: command))
        #expect(vm != nil, Comment(rawValue: row.id))
        #expect(vm?.nextAction == denyNextAction, Comment(rawValue: row.id))
        if let needle = row.reasonContains {
            #expect(vm?.fact.contains(needle) == true, Comment(rawValue: row.id))
        }
        let text = hostDenyText(from: result, command: ShellCommand(rawValue: command))
        #expect(text != nil, Comment(rawValue: row.id))
        #expect(text?.contains("\n") == false, Comment(rawValue: row.id))
        #expect(text?.contains("═") == false, Comment(rawValue: row.id))
        #expect(text?.contains("┌") == false, Comment(rawValue: row.id))
        if let ruleID = row.ruleID, let parsed = RuleID(rawValue: ruleID) {
            #expect(text?.contains(displayRuleID(parsed)) == true, Comment(rawValue: row.id))
        }
        let lines = DenyRenderer().render(vm!, palette: colorOffPalette)
        #expect(lines.contains { $0.contains(displayRuleID(deny.ruleID)) }, Comment(rawValue: row.id))
        #expect(lines.contains(denyNextAction), Comment(rawValue: row.id))
        #expect(lines.allSatisfy { $0.count <= 80 || $0.contains(command) }, Comment(rawValue: row.id))
    }
}

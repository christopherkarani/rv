import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

@Suite struct CatalogEnablementCorpusTests {
    @Test func sqliteDropTable_allowsByDefault_deniesWhenEnabled() throws {
        let sqlite = try PackRegistry.loadDocument(id: "database.sqlite").snapshot
        let core = try PackRegistry.loadDayOne()
        let packs = core + [sqlite]
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks.compile(packs: packs, using: engine)
        let command = ShellCommand(rawValue: "DROP TABLE users")

        let off = evaluate(
            EvaluationRequest(command: command, enabledPacks: PackSet.defaultIDs),
            packs: packs,
            patterns: engine,
            compiled: compiled
        )
        #expect(off.decision == .allow)

        let on = evaluate(
            EvaluationRequest(
                command: command,
                enabledPacks: PackSet.defaultIDs + [PackID(rawValue: "database.sqlite")]
            ),
            packs: packs,
            patterns: engine,
            compiled: compiled
        )
        guard case .deny(let deny) = on.decision else {
            Issue.record("expected deny, got \(on.decision)")
            return
        }
        #expect(deny.ruleID.rawValue == "database.sqlite:drop-table")
    }

    @Test func resetHard_stillDeniesWithFullCatalogLoaded() throws {
        let packs = try PackRegistry.loadAll()
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks.compile(packs: packs, using: engine)
        let result = evaluate(
            EvaluationRequest.makeDayOne(command: ShellCommand(rawValue: "git reset --hard")),
            packs: packs,
            patterns: engine,
            compiled: compiled
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("expected deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }
}

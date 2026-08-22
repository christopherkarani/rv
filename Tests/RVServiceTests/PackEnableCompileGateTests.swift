import Testing
import RVDomain
import RVEngine
@testable import RVService

private struct RejectingEngine: PatternEngine {
    func compile(_ pattern: String) throws(PatternCompileError) -> String {
        throw PatternCompileError.invalidPattern(name: pattern, message: "reject")
    }

    func matches(_ compiled: String, in text: String) -> Bool { false }

    func firstMatch(_ compiled: String, in text: String) -> Range<String.Index>? { nil }
}

private struct AcceptingEngine: PatternEngine {
    func compile(_ pattern: String) throws(PatternCompileError) -> String { pattern }
    func matches(_ compiled: String, in text: String) -> Bool { false }
    func firstMatch(_ compiled: String, in text: String) -> Range<String.Index>? { nil }
}

@Test func enableCompileGate_rejectsUncompilableCritical() {
    let pack = PackSnapshot(
        id: PackID(rawValue: "database.sqlite"),
        name: "SQLite",
        description: "test",
        keywords: ["drop"],
        safe: [],
        destructive: [
            DestructiveRule(
                name: "drop-table",
                pattern: "(?P<bad>",
                severity: .critical,
                reason: "drops a table",
                explanation: nil
            ),
        ]
    )
    let ruleID = PackEnableCompileGate.firstUncompilableBlockingRule(
        in: [pack],
        using: RejectingEngine()
    )
    #expect(ruleID?.rawValue == "database.sqlite:drop-table")
}

@Test func enableCompileGate_allowsMediumMissAndCompilableCritical() {
    let pack = PackSnapshot(
        id: PackID(rawValue: "database.sqlite"),
        name: "SQLite",
        description: "test",
        keywords: ["drop"],
        safe: [],
        destructive: [
            DestructiveRule(
                name: "medium-miss",
                pattern: "(?P<bad>",
                severity: .medium,
                reason: "noise",
                explanation: nil
            ),
            DestructiveRule(
                name: "drop-table",
                pattern: "DROP TABLE",
                severity: .critical,
                reason: "drops a table",
                explanation: nil
            ),
        ]
    )
    let ruleID = PackEnableCompileGate.firstUncompilableBlockingRule(
        in: [pack],
        using: AcceptingEngine()
    )
    #expect(ruleID == nil)
}

@Test func enableCompileGate_bundledDatabaseSqliteBlockingPatternsCompile() throws {
    let packID = try #require(PackID(validating: "database.sqlite"))
    try PackEnableCompileGate.assertBlockingPatternsCompile(packIDs: [packID])
}

import Testing
@testable import RVEngine

@Test func icu_compilesAndMatchesResetHard() throws {
    let engine = ICUPatternEngine()
    let compiled = try engine.compile(#"(?:^|[^[:alnum:]_-])git\s+(?:\S+\s+)*reset\s+--hard"#)
    #expect(engine.matches(compiled, in: "git reset --hard"))
    #expect(!engine.matches(compiled, in: "git reset --soft"))
}

@Test func icu_unsatisfiableLookaheadNeverMatches() throws {
    let engine = ICUPatternEngine()
    let compiled = try engine.compile("(?!)")
    #expect(!engine.matches(compiled, in: "git myalias"))
    #expect(!engine.matches(compiled, in: "git reset --hard"))
}

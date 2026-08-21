import Testing
@testable import RVEngine

@Test func icu_compilesAndMatchesResetHard() throws {
    let engine = ICUPatternEngine()
    let compiled = try engine.compile(#"(?:^|[^[:alnum:]_-])git\s+(?:\S+\s+)*reset\s+--hard"#)
    #expect(engine.matches(compiled, in: "git reset --hard"))
    #expect(!engine.matches(compiled, in: "git reset --soft"))
}

@Test func icu_firstMatchReportsCharacterRange() throws {
    let engine = ICUPatternEngine()
    let reset = try engine.compile(#"(?:^|[^[:alnum:]_-])git\s+(?:\S+\s+)*reset\s+--hard"#)
    let resetRange = try #require(engine.firstMatch(reset, in: "git reset --hard"))
    let resetText = "git reset --hard"
    #expect(resetText[resetRange] == "git reset --hard")
    #expect(resetText.distance(from: resetText.startIndex, to: resetRange.lowerBound) == 0)
    #expect(resetText.distance(from: resetText.startIndex, to: resetRange.upperBound) == 16)

    let rm = try engine.compile(#"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f"#)
    let rmText = "rm -rf ./src"
    let rmRange = try #require(engine.firstMatch(rm, in: rmText))
    #expect(String(rmText[rmRange]) == "rm -rf")
}

@Test func icu_unsatisfiableLookaheadNeverMatches() throws {
    let engine = ICUPatternEngine()
    let compiled = try engine.compile("(?!)")
    #expect(!engine.matches(compiled, in: "git myalias"))
    #expect(!engine.matches(compiled, in: "git reset --hard"))
}

private struct FirstMatchOnlyEngine: PatternEngine {
    func compile(_ pattern: String) throws(PatternCompileError) -> String { pattern }

    func firstMatch(_ compiled: String, in text: String) -> Range<String.Index>? {
        text.range(of: compiled)
    }
}

@Test func patternEngine_defaultMatchesFollowsFirstMatch() {
    let engine = FirstMatchOnlyEngine()
    #expect(engine.matches("reset", in: "git reset --hard"))
    #expect(!engine.matches("soft", in: "git reset --hard"))
}

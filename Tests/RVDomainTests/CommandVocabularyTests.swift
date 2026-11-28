import Testing
import RVDomain

/// The vocabulary table's own facts. Its agreement with the parser, help
/// and docs is proven in `RVCLITests` (`CommandVocabularyParityTests`).
@Suite("Command vocabulary")
struct CommandVocabularyTests {
    @Test func invocationIsProgramThenSpelling() {
        #expect(CommandVocabulary.Command.allowOnce.invocation == "rv allow-once")
        #expect(CommandVocabulary.Command.initialize.invocation == "rv init")
        #expect(CommandVocabulary.Command.operator.invocation == "rv operator")
    }

    @Test func spellingsAreUniqueLowercaseWords() {
        let spellings = CommandVocabulary.Command.allCases.map(\.rawValue)
        #expect(Set(spellings).count == spellings.count)
        for spelling in spellings {
            #expect(spelling == spelling.lowercased() && spelling.contains(" ") == false, "\(spelling)")
        }
    }

    @Test func sixGlyphsWithTheirWords() {
        let pairs = CommandVocabulary.Glyph.allCases.map { "\($0.rawValue) \($0.word)" }
        #expect(pairs == ["◆ rv", "✕ Stopped", "◐ Watched", "✓ Done", "→ Next", "⏺ Asks"])
        let events = CommandVocabulary.Glyph.allCases.compactMap { glyph in glyph.eventWord.map { "\(glyph.rawValue) \($0)" } }
        #expect(events == ["✕ stopped", "◐ would stop", "✓ ran", "⏺ asks"])
    }

    @Test func verdictWords() {
        typealias Verdict = CommandVocabulary.Verdict
        #expect([Verdict.allow, Verdict.deny, Verdict.ask, Verdict.incomplete] == ["allow", "deny", "ask", "incomplete"])
        #expect([Verdict.allowed, Verdict.blocked] == ["allowed", "blocked"])
    }

    /// Chris chose `rv protect <tool>` (2026-11-22); G6 shipped it, so it
    /// is a command and no longer a planned name.
    @Test func protectShipped() {
        #expect(CommandVocabulary.Command.protect.invocation == "rv protect")
        #expect(CommandVocabulary.plannedNames.contains { $0.spelling.hasPrefix("rv protect") } == false)
    }

    @Test func plannedTopLevelWordsAreNotCommandsYet() {
        let commands = Set(CommandVocabulary.Command.allCases.map(\.rawValue))
        let words = CommandVocabulary.plannedNames.map { $0.spelling.split(separator: " ").map(String.init) }
        #expect(words.allSatisfy { $0.first == CommandVocabulary.program })
        let newWords = Set(words.map { $0[1] }).subtracting(commands)
        #expect(newWords == ["guard", "keys", "rules", "unlock", "watch", "why"])
        let spellings = CommandVocabulary.plannedNames.map(\.spelling)
        #expect(Set(spellings).count == spellings.count)
    }

    @Test func plannedNamesReplaceCommandsRvHasToday() {
        for planned in CommandVocabulary.plannedNames {
            guard let today = planned.today else { continue }
            let word = today.split(separator: " ").dropFirst().first.map(String.init)
            #expect(word.flatMap(CommandVocabulary.Command.init(rawValue:)) != nil, "\(today)")
        }
    }
}

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

    @Test func protectIsDecidedByChris() {
        let protect = CommandVocabulary.plannedNames.filter { $0.spelling.hasPrefix("rv protect ") }
        #expect(protect.map(\.today) == ["rv packs enable <pack>", "rv packs disable <pack>"])
        #expect(protect.allSatisfy { $0.status == .decided })
    }

    @Test func plannedTopLevelWordsAreNotCommandsYet() {
        let commands = Set(CommandVocabulary.Command.allCases.map(\.rawValue))
        let words = CommandVocabulary.plannedNames.map { $0.spelling.split(separator: " ").map(String.init) }
        #expect(words.allSatisfy { $0.first == CommandVocabulary.program })
        let newWords = Set(words.map { $0[1] }).subtracting(commands)
        #expect(newWords == ["keys", "log", "protect", "rules"])
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

    @Test func aliasesNameTheirOldSpellings() {
        let pairs = CommandVocabulary.Alias.allCases.map { "\($0.spelling) = \($0.target)" }
        #expect(pairs == [
            "rv why = rv explain",
            "rv unlock = rv allow-once",
            "rv guard <host> = rv host mode <host> block",
            "rv watch <host> = rv host mode <host> observe",
            "rv secrets add = rv secrets set",
        ])
    }

    @Test func aliasesRunCommandsRvHas() {
        for alias in CommandVocabulary.Alias.allCases {
            #expect(alias.runs.first.flatMap(CommandVocabulary.Command.init(rawValue:)) != nil, "\(alias)")
            let first = alias.words[0]
            // A new top-level word is not a command; `secrets add` is under one.
            #expect((CommandVocabulary.Command(rawValue: first) != nil) == (alias.words.count > 1), "\(alias)")
        }
    }

    @Test func expandFillsTheHostSlot() {
        #expect(CommandVocabulary.expand(["guard", "claude"]) == .expanded(["host", "mode", "claude", "block"]))
        #expect(CommandVocabulary.expand(["watch", "--json", "cursor"]) == .expanded(["host", "mode", "--json", "cursor", "observe"]))
        #expect(CommandVocabulary.expand(["guard"]) == .missingArgument(.guard))
        #expect(CommandVocabulary.expand(["guard", "-h"]) == .expanded(["host", "mode", "-h"]))
        #expect(CommandVocabulary.expand(["why"]) == .expanded(["explain"]))
        #expect(CommandVocabulary.expand(["secrets", "add", "K"]) == .expanded(["secrets", "set", "K"]))
        #expect(CommandVocabulary.expand(["secrets", "list"]) == .unchanged)
        #expect(CommandVocabulary.expand(["explain", "why"]) == .unchanged)
        #expect(CommandVocabulary.expand([]) == .unchanged)
    }
}

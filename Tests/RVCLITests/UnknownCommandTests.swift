import RVDomain
import Testing
@testable import RVCLI

struct UnknownCommandTests {
    @Test func typosSuggestTheClosestCommand() {
        #expect(UnknownCommand.message(arguments: ["explian", "ls"])?.contains("Did you mean 'rv explain'?") == true)
        #expect(UnknownCommand.message(arguments: ["doctr"])?.contains("Did you mean 'rv doctor'?") == true)
        #expect(UnknownCommand.message(arguments: ["blcoks"])?.contains("Did you mean 'rv blocks'?") == true)
        #expect(UnknownCommand.suggestion(for: "stauts", among: ["status", "setup"]) == "status")
    }

    @Test func farOffWordsGetNoGuess() {
        let text = UnknownCommand.message(arguments: ["frobnicate"])
        #expect(text?.contains("unknown command 'frobnicate'") == true)
        #expect(text?.contains("Did you mean") == false)
        #expect(text?.contains("rv --help") == true)
    }

    @Test func realCommandsFlagsAndEmptyAreLeftToTheParser() {
        #expect(UnknownCommand.message(arguments: []) == nil)
        #expect(UnknownCommand.message(arguments: ["--version"]) == nil)
        #expect(UnknownCommand.message(arguments: ["help", "explain"]) == nil)
        // `rv guard` and `rv watch` alone name no agent: CommandAliasTests.
        for name in UnknownCommand.known where CommandAlias.refusal([name]) == nil {
            #expect(UnknownCommand.message(arguments: [name]) == nil, "\(name) is a real command")
        }
    }

    @Test func internalCommandsAreKnownButNeverSuggested() {
        for typo in ["hok", "hoook", "opertor", "operater"] {
            let text = UnknownCommand.message(arguments: [typo])
            #expect(text?.contains("Did you mean") == false, "\(typo): \(text ?? "nil")")
        }
        #expect(UnknownCommand.message(arguments: ["hook", "--host", "claude"]) == nil)
        #expect(UnknownCommand.message(arguments: ["operator"]) == nil)
        #expect(UnknownCommand.candidates.contains("hook") == false)
        #expect(UnknownCommand.candidates.contains("operator") == false)
        #expect(UnknownCommand.candidates.contains("doctor"))
    }

    @Test func aTypedControlCharacterIsEscapedNotEchoed() {
        let text = UnknownCommand.message(arguments: ["x\u{1B}[2J"])
        #expect(text?.contains("\u{1B}") == false)
    }

    @Test func everyCommandInTheVocabularyTableIsKnown() {
        for command in CommandVocabulary.Command.allCases {
            #expect(UnknownCommand.message(arguments: [command.rawValue]) == nil, "\(command.rawValue)")
        }
    }

    @Test func editDistanceCountsATranspositionOnce() {
        #expect(UnknownCommand.editDistance("stauts", "status") == 1)
        #expect(UnknownCommand.editDistance("", "abc") == 3)
        #expect(UnknownCommand.editDistance("same", "same") == 0)
    }
}

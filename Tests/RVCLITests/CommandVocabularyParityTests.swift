import ArgumentParser
import Foundation
import RVDomain
import Testing
@testable import RVCLI

/// `CommandVocabulary` names every command rv has, and nothing a person
/// reads names a command it does not: the parser, every help page, the
/// README and the guides.
@Suite("Command vocabulary matches the parser, help and docs")
struct CommandVocabularyParityTests {
    /// Spellings in the table.
    static let commands = Set(CommandVocabulary.Command.allCases.map(\.rawValue))

    /// Commands PR #662 adds to the parser. Whichever lands second adds
    /// them to `CommandVocabulary.Command` and deletes this set.
    static let landingWith662: Set = ["status", "version"]

    @Test("the table and the parser name the same top-level commands")
    func tableMatchesParser() {
        let parsed = Set(RV.configuration.subcommands.map { $0._commandName })
        let helpOnly: Set = [CommandVocabulary.Command.help.rawValue]
        let missing = parsed.subtracting(Self.commands).subtracting(Self.landingWith662)
        let extra = Self.commands.subtracting(parsed).subtracting(helpOnly)
        #expect(missing.isEmpty, "commands the parser has and CommandVocabulary does not: \(missing.sorted())")
        #expect(extra.isEmpty, "commands CommandVocabulary has and the parser does not: \(extra.sorted())")
    }

    @Test("rv --help lists only commands in the table")
    func rootHelpRowsAreCommands() {
        let rows = HelpCatalog.page(.root).sections.flatMap(\.rows).map(\.name)
        let unknown = rows.filter { $0 != CommandVocabulary.program && Self.commands.contains($0) == false }
        #expect(unknown.isEmpty, "root help rows not in CommandVocabulary: \(unknown)")
        #expect(rows.isEmpty == false)
    }

    @Test("every rv spelling on every help page starts with a command in the table")
    func helpSpellingsAreCommands() {
        var unknown: [String] = []
        for topic in HelpTopic.allCases {
            let page = HelpCatalog.page(topic)
            let spellings = page.sections.flatMap(\.rows).map(\.name)
                + page.examples
                + page.next.map(\.command)
            for spelling in spellings {
                if let word = Self.commandWord(in: spelling), Self.commands.contains(word) == false {
                    unknown.append("\(topic): \(spelling)")
                }
            }
        }
        #expect(unknown.isEmpty, "help names commands not in CommandVocabulary:\n\(unknown.joined(separator: "\n"))")
    }

    /// rv's own messages, quoted in the docs, begin `rv <verb>`.
    static let messageWords: Set = [
        "at", "blocked", "cannot", "could", "degraded", "did", "exited", "is", "paused",
    ]

    @Test("README and the guides name only commands in the table")
    func docsNameOnlyCommands() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let guides = root.appendingPathComponent("docs/guides")
        let files = [root.appendingPathComponent("README.md")]
            + (try FileManager.default.contentsOfDirectory(at: guides, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "md" }
        var unknown: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, spelling) in Self.docSpellings(text) {
                guard let word = Self.commandWord(in: spelling) else { continue }
                if Self.commands.contains(word) || Self.messageWords.contains(word) { continue }
                unknown.append("\(file.lastPathComponent):\(number): \(spelling)")
            }
        }
        #expect(files.count > 1)
        #expect(unknown.isEmpty, "docs name commands not in CommandVocabulary:\n\(unknown.joined(separator: "\n"))")
    }

    @Test("planned names are data only: the parser refuses every one today")
    func plannedNamesDoNotParse() {
        for planned in CommandVocabulary.plannedNames {
            let argv = planned.spelling.split(separator: " ").dropFirst()
                .map { $0.hasPrefix("<") ? "x" : String($0) }
            #expect(throws: (any Error).self, "\(planned.spelling) parses; move it out of plannedNames") {
                _ = try RV.parseAsRoot(argv)
            }
        }
    }

    @Test("rv help help still reaches the help page through the table")
    func helpWordComesFromTable() {
        let help = CommandVocabulary.Command.help.rawValue
        #expect(HelpDispatch.topic(arguments: [help]) == .root)
        #expect(HelpDispatch.topic(arguments: [help, help]) == .help)
    }

    /// The command word of `rv <word> …` (a trailing `:` dropped, as in
    /// `rv mcp: …` messages), or `nil` when `spelling` is not an rv
    /// command: bare `rv`, a flag, a placeholder, or prose.
    static func commandWord(in spelling: String) -> String? {
        let words = spelling.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 1, words[0] == Substring(CommandVocabulary.program) else { return nil }
        var word = String(words[1])
        if word.hasSuffix(":") { word.removeLast() }
        guard let first = word.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else { return nil }
        return word
    }

    /// `rv …` spellings in Markdown: inline code spans, and lines of fenced
    /// blocks (a leading `$ ` prompt dropped), with their line numbers.
    static func docSpellings(_ markdown: String) -> [(Int, String)] {
        var found: [(Int, String)] = []
        var fenced = false
        for (index, line) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                fenced.toggle()
                continue
            }
            if fenced {
                let command = trimmed.hasPrefix("$ ") ? String(trimmed.dropFirst(2)) : trimmed
                if command.hasPrefix("rv ") { found.append((index + 1, command)) }
                continue
            }
            let spans = line.split(separator: "`", omittingEmptySubsequences: false)
            for (position, span) in spans.enumerated() where position % 2 == 1 && span.hasPrefix("rv ") {
                found.append((index + 1, String(span)))
            }
        }
        return found
    }
}

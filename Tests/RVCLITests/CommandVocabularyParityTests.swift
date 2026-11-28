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

    /// What help and docs may name: the table, plus #662's commands.
    static let known = commands.union(landingWith662)

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
        let unknown = rows.filter { $0 != CommandVocabulary.program && Self.known.contains($0) == false }
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
                if let word = Self.commandWord(in: spelling), Self.known.contains(word) == false {
                    unknown.append("\(topic): \(spelling)")
                }
            }
        }
        #expect(unknown.isEmpty, "help names commands not in CommandVocabulary:\n\(unknown.joined(separator: "\n"))")
    }

    /// Top-level words of planned names that rv does not accept yet.
    static let plannedWords = Set(CommandVocabulary.plannedNames.compactMap { planned in
        planned.spelling.split(separator: " ").dropFirst().first.map(String.init)
    }).subtracting(known)

    /// Words of rv's own messages that sit one edit from a command:
    /// "rv paused this call" (the MCP gateway) is not a typo of `rv pause`.
    static let messageWords: Set = ["paused"]

    /// Docs quote rv's own messages in code too (`rv is not installed at
    /// <path>`), so a code span is held to the table only when it is a
    /// command: a `$ rv …` prompt line, or a word that is a planned name
    /// (a rename the parser does not accept yet) or one edit away from a
    /// table command (a typo). Any other `rv <word>` is a quoted message.
    static func docNamesUnknownCommand(_ spelling: DocSpelling) -> Bool {
        guard let word = commandWord(in: spelling.text), known.contains(word) == false else { return false }
        if spelling.isPrompt || plannedWords.contains(word) { return true }
        if messageWords.contains(word) { return false }
        return known.contains { editDistance(word, $0) <= 1 }
    }

    @Test("README and the guides name only commands in the table")
    func docsNameOnlyCommands() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let guides = root.appendingPathComponent("docs/guides")
        let walk = try #require(FileManager.default.enumerator(at: guides, includingPropertiesForKeys: nil))
        let files = [root.appendingPathComponent("README.md")]
            + walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
        var unknown: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for spelling in Self.docSpellings(text) where Self.docNamesUnknownCommand(spelling) {
                unknown.append("\(file.lastPathComponent):\(spelling.line): \(spelling.text)")
            }
        }
        #expect(files.count > 1)
        #expect(unknown.isEmpty, "docs name commands not in CommandVocabulary:\n\(unknown.joined(separator: "\n"))")
    }

    @Test("the docs check catches prompts, planned names and typos, not quoted messages")
    func docCheckSeparatesCommandsFromMessages() {
        let flagged = Self.docSpellings("""
            Run `rv stauts` or `rv why 'git reset --hard'`.
            ```
            $ rv frobnicate
            rv is not installed at <path>
            ```
            `rv is not installed at <path>`, `rv mcp: server is back`, `rv blocks --json`
            """).filter(Self.docNamesUnknownCommand).map(\.text)
        #expect(flagged == ["rv stauts", "rv why 'git reset --hard'", "rv frobnicate"])
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

    /// One `rv …` spelling found in Markdown code.
    struct DocSpelling {
        var line: Int
        var text: String
        /// A fenced line with a `$ ` prompt: certainly a command.
        var isPrompt: Bool
    }

    /// `rv …` spellings in Markdown code: inline code spans, and lines of
    /// fenced blocks (a leading `$ ` prompt dropped). Prose outside
    /// backticks is never read.
    static func docSpellings(_ markdown: String) -> [DocSpelling] {
        var found: [DocSpelling] = []
        var fenced = false
        for (index, line) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                fenced.toggle()
                continue
            }
            if fenced {
                let isPrompt = trimmed.hasPrefix("$ ")
                let command = isPrompt ? String(trimmed.dropFirst(2)) : trimmed
                if command.hasPrefix("rv ") {
                    found.append(DocSpelling(line: index + 1, text: command, isPrompt: isPrompt))
                }
                continue
            }
            let spans = line.split(separator: "`", omittingEmptySubsequences: false)
            for (position, span) in spans.enumerated() where position % 2 == 1 && span.hasPrefix("rv ") {
                found.append(DocSpelling(line: index + 1, text: String(span), isPrompt: false))
            }
        }
        return found
    }

    /// Optimal string alignment distance: insertions, deletions,
    /// substitutions and adjacent transpositions (`stauts` → `status` is 1).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        guard s.isEmpty == false else { return t.count }
        guard t.isEmpty == false else { return s.count }
        var d = Array(repeating: Array(repeating: 0, count: t.count + 1), count: s.count + 1)
        for i in 0...s.count { d[i][0] = i }
        for j in 0...t.count { d[0][j] = j }
        for i in 1...s.count {
            for j in 1...t.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (s[i - 1] == t[j - 1] ? 0 : 1))
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[s.count][t.count]
    }
}

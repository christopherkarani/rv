import ArgumentParser
import Foundation
import RVDomain

/// `rv stauts`: ArgumentParser answers an unknown subcommand with a bare
/// "Unexpected argument". This names the closest real command instead.
public enum UnknownCommand {
    /// Every top-level spelling a user can type: the vocabulary table
    /// (which includes `help`), plus every name and alias the parser
    /// accepts, so a command or alias added later is never refused here.
    static var known: [String] {
        let table = CommandVocabulary.Command.allCases.map(\.rawValue)
        let parsed = RV.configuration.subcommands.flatMap { command in
            [command._commandName] + command.configuration.aliases
        }
        var seen = Set<String>()
        return (table + parsed).filter { seen.insert($0).inserted }
    }

    /// Commands rv runs for a program, not a person: the hook entry point
    /// agent hosts call, and machine-to-machine identity launches. They
    /// stay known, so they are never refused, but a typo never suggests one.
    static let internalCommands: Set<CommandVocabulary.Command> = [.hook, .operator]

    /// What a typo may be corrected to: every known spelling but the
    /// internal commands.
    static var candidates: [String] {
        let hidden = Set(internalCommands.map(\.rawValue))
        return known.filter { hidden.contains($0) == false }
    }

    /// The message for `arguments` when its first word is not a command,
    /// or `nil` when ArgumentParser should handle it (a flag, a real
    /// command, or no arguments).
    public static func message(
        arguments: [String], known: [String]? = nil, candidates: [String]? = nil
    ) -> String? {
        guard let first = arguments.first, first.hasPrefix("-") == false else { return nil }
        if let refusal = VersionSpelling.refusal(arguments) { return refusal }
        let names = known ?? Self.known
        guard names.contains(first) == false else { return nil }
        let suggestible = candidates ?? (known == nil ? Self.candidates : names)
        let program = CommandVocabulary.program
        let shown = DisplayedText.field(first)
        var text = "\(program): unknown command '\(shown)'."
        if let match = suggestion(for: first, among: suggestible) {
            text += " Did you mean '\(program) \(match)'?"
        }
        return text + " Run \(program) --help to see every command.\n"
    }

    /// The closest name within an edit distance that scales with length
    /// (1 for short words, up to 3), or one the word is a prefix of.
    static func suggestion(for word: String, among names: [String]) -> String? {
        let lower = word.lowercased()
        let limit = min(3, max(1, lower.count / 3))
        let scored = names
            .map { (name: $0, distance: editDistance(lower, $0)) }
            .filter { $0.distance <= limit }
            .sorted { ($0.distance, $0.name) < ($1.distance, $1.name) }
        if let best = scored.first { return best.name }
        let prefixed = names.filter { $0.hasPrefix(lower) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// Optimal string alignment distance: insertions, deletions,
    /// substitutions and adjacent transpositions (`stauts` → `status` is 1).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var d = Array(repeating: Array(repeating: 0, count: t.count + 1), count: s.count + 1)
        for i in 0...s.count { d[i][0] = i }
        for j in 0...t.count { d[0][j] = j }
        for i in 1...s.count {
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[s.count][t.count]
    }
}

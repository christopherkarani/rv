import RVDomain
import ArgumentParser
import Foundation
@testable import RVCLI

/// Test helpers over `CommandGrammar`, the parser's own description of
/// rv's commands. Tests derive their argv from it instead of keeping their
/// own flag lists.
extension CommandGrammar.Command {
    /// Every command under this one with its path, this one first.
    /// ArgumentParser's built-in `help` command is left out.
    func walk(path: [String] = []) -> [(path: [String], command: Self)] {
        [(path, self)] + (subcommands ?? [])
            .filter { $0.commandName != "help" }
            .flatMap { $0.walk(path: path + [$0.commandName]) }
    }

    /// Argument vectors that hand `--help` to `path` after each of its own
    /// arguments, one at a time (earlier positionals filled in so the one
    /// under test lands in its own slot). On a command with a passthrough
    /// capture, the first positional starts the capture, so `--help` after
    /// any positional belongs to the captured command: those are in
    /// `passthrough`. Each value is one the argument takes (its first
    /// enumerated value, else `1`), so the parser reads it too.
    func helpProbes(path: [String]) -> (own: [[String]], passthrough: [[String]]) {
        var own: [[String]] = []
        var passthrough: [[String]] = []
        var positionals: [String] = []
        for argument in arguments ?? [] where argument.isHelp == false {
            let value = argument.allValues?.first ?? "1"
            switch argument.kind {
            case .option:
                guard let spelling = argument.spellings.first else { continue }
                own.append(path + [spelling, value, "--help"])
                own.append(path + ["\(spelling)=\(value)", "--help"])
            case .flag:
                guard let spelling = argument.spellings.first else { continue }
                own.append(path + [spelling, "--help"])
            case .positional:
                if capturesPassthrough {
                    passthrough.append(path + positionals + [value, "--help"])
                } else {
                    own.append(path + positionals + [value, "--help"])
                }
                positionals.append(value)
            }
        }
        return (own, passthrough)
    }
}

/// Turns a help usage row (`rv policy show [--base] [--effective]`) into
/// argument vectors the real parser must accept: without any optional
/// part, and with every optional part (first and last alternatives).
/// Placeholders get a value the argument takes: its first enumerated value
/// from the grammar, else a plausible one by name.
enum UsageRow {
    enum Mode: CaseIterable {
        case bare, fullFirst, fullLast
    }

    private indirect enum Node {
        case word(String)
        /// `[a | b]`: optional, with alternatives.
        case optional([[Node]])
    }

    /// `row` with a new name (`rv why`, `rv guard <host>`) spelled the way
    /// the parser knows it (`rv explain`, `rv host mode <host> block`),
    /// as `CommandAlias` rewrites it before the parser runs.
    static func spelledAsParsed(_ row: String) -> String {
        for alias in CommandVocabulary.Alias.allCases {
            let typed = alias.spelling
            guard row == typed || row.hasPrefix(typed + " ") else { continue }
            return alias.target + row.dropFirst(typed.count)
        }
        return row
    }

    /// The argv (without `rv`) for `row` in `mode`.
    static func argv(_ row: String, mode: Mode) -> [String] {
        var tokens = tokenize(String(spelledAsParsed(row).dropFirst(3)))[...]
        var alternatives = alternatives(&tokens)
        // `rv mcp pending | approve <id> | deny <id>`: later alternatives
        // share the first one's leading words.
        let shared = alternatives[0].dropLast()
        for index in alternatives.indices.dropFirst() {
            alternatives[index] = Array(shared) + alternatives[index]
        }
        let chosen = mode == .fullLast ? alternatives[alternatives.count - 1] : alternatives[0]
        return fill(expand(chosen, mode: mode))
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        var angle = 0
        var glued = 0
        func flush() {
            if word.isEmpty == false { tokens.append(word) }
            word = ""
        }
        for character in text {
            if character == "<" { angle += 1 }
            if character == ">" { angle -= 1 }
            if glued > 0 || (character == "[" && word.isEmpty == false && angle == 0) {
                // `<id>[:<endpoint>]`: an optional suffix of one word.
                if character == "[" { glued += 1 }
                if character == "]" { glued -= 1 }
                word.append(character)
            } else if angle == 0, character == "[" || character == "]" || (character == "|" && word.isEmpty) {
                flush()
                tokens.append(String(character))
            } else if angle == 0, character == " " {
                flush()
            } else {
                word.append(character)
            }
        }
        flush()
        return tokens
    }

    private static func alternatives(_ tokens: inout ArraySlice<String>) -> [[Node]] {
        var result: [[Node]] = [[]]
        while let token = tokens.first, token != "]" {
            tokens.removeFirst()
            switch token {
            case "|":
                result.append([])
            case "[":
                let inner = alternatives(&tokens)
                if tokens.first == "]" { tokens.removeFirst() }
                result[result.count - 1].append(.optional(inner))
            default:
                result[result.count - 1].append(.word(token))
            }
        }
        return result
    }

    private enum Word {
        case literal(String)
        case placeholder(String)
    }

    private static func expand(_ nodes: [Node], mode: Mode) -> [Word] {
        nodes.flatMap { node -> [Word] in
            switch node {
            case .word(let word):
                return classify(word, mode: mode).map { [$0] } ?? []
            case .optional(let options):
                guard mode != .bare else { return [] }
                return expand(mode == .fullLast ? options[options.count - 1] : options[0], mode: mode)
            }
        }
    }

    private static func classify(_ word: String, mode: Mode) -> Word? {
        var word = word
        if word == "..." { return nil }
        if word.hasSuffix("...") { word = String(word.dropLast(3)) }
        if let glued = word.firstIndex(of: "["), word.hasPrefix("[") == false { word = String(word[..<glued]) }
        let choices = splitChoices(word)
        if choices.count > 1 { return classify(mode == .fullLast ? choices[choices.count - 1] : choices[0], mode: mode) }
        if word == "N" || word == "M" { return .placeholder("n") }
        guard word.hasPrefix("<"), word.hasSuffix(">") else { return .literal(word) }
        let inner = String(word.dropFirst().dropLast())
        let innerChoices = inner.split(separator: "|").map(String.init)
        if innerChoices.count > 1 { return .literal(mode == .fullLast ? innerChoices[innerChoices.count - 1] : innerChoices[0]) }
        return .placeholder(inner)
    }

    /// `rv|ocsf`, `<date>|none`: `|` outside angle brackets.
    private static func splitChoices(_ word: String) -> [String] {
        var parts = [""]
        var angle = 0
        for character in word {
            if character == "<" { angle += 1 }
            if character == ">" { angle -= 1 }
            if character == "|", angle == 0 { parts.append("") } else { parts[parts.count - 1].append(character) }
        }
        return parts
    }

    /// Walks the words through the grammar so each placeholder gets a value
    /// its argument takes.
    private static func fill(_ words: [Word]) -> [String] {
        guard var node = CommandGrammar.rv?.command else { return [] }
        var positional = 0
        var pending: CommandGrammar.Argument?
        var argv: [String] = []
        func positionals(_ node: CommandGrammar.Command) -> [CommandGrammar.Argument] {
            (node.arguments ?? []).filter { $0.kind == .positional }
        }
        for word in words {
            switch word {
            case .literal(let text):
                if pending == nil, let child = node.subcommand(named: text) {
                    node = child
                    positional = 0
                } else if text.hasPrefix("-") {
                    var argument = node.argument(spelled: text)
                    if argument == nil, let name = node.defaultSubcommand, let child = node.subcommand(named: name),
                       let found = child.argument(spelled: text)
                    {
                        node = child
                        positional = 0
                        argument = found
                    }
                    pending = argument?.kind == .option && text.contains("=") == false ? argument : nil
                } else if pending != nil {
                    pending = nil
                } else {
                    positional += 1
                }
                argv.append(text)
            case .placeholder(let name):
                var argument = pending
                if argument == nil {
                    let all = positionals(node)
                    argument = all.isEmpty ? nil : all[min(positional, all.count - 1)]
                    positional += 1
                }
                pending = nil
                argv.append(argument?.allValues?.first ?? placeholderValues[name] ?? "x")
            }
        }
        return argv
    }

    /// Placeholders whose parser wants more than any string.
    static let placeholderValues: [String: String] = [
        "n": "1",
        "seconds": "10",
        "host": "claude",
        "rule": "read-only",
        "count": "1",
        "revision": "1",
        "code": "123456",
        "date": "2026-12-31",
        "interval": "15m",
        "provider": "vercel",
        "s": "header",
        "policy.toml": "policy.toml",
    ]
}

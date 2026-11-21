import ArgumentParser
import Foundation

/// rv's command grammar as ArgumentParser itself describes it: every
/// command, option, flag and positional the parser accepts, read from the
/// parser's own `--experimental-dump-help` description of `RV`. The
/// `@Option` / `@Flag` / `@Argument` declarations stay the only place a
/// flag is spelled; help dispatch and the help tests read them from here.
///
/// Only the fields rv reads are decoded, so a change to any other part of
/// the dump cannot stop it loading. If a field rv reads changes, decoding
/// fails and `rv` is `nil`.
struct CommandGrammar: Decodable, Sendable {
    struct Name: Decodable, Sendable {
        var kind: String
        var name: String

        /// What a user types: `--name`, `-n`, or `-name`.
        var spelling: String {
            switch kind {
            case "long": "--" + name
            default: "-" + name
            }
        }
    }

    struct Argument: Decodable, Sendable {
        enum Kind: String, Decodable, Sendable {
            case positional, option, flag
        }

        var kind: Kind
        var names: [Name]?
        var parsingStrategy: String
        /// The values an enumerated argument takes, when it has a fixed set.
        var allValues: [String]?

        /// Every spelling, long names first.
        var spellings: [String] {
            (names ?? []).sorted { $0.kind == "long" && $1.kind != "long" }.map(\.spelling)
        }

        /// ArgumentParser's own `--help` / `-h`.
        var isHelp: Bool { spellings.contains("--help") }

        /// `.captureForPassthrough`: from the first positional or unknown
        /// option on, every input is this argument's, `--help` included.
        var capturesPassthrough: Bool { parsingStrategy == "allRemainingInput" }
    }

    struct Command: Decodable, Sendable {
        var commandName: String
        var aliases: [String]?
        var defaultSubcommand: String?
        var arguments: [Argument]?
        var subcommands: [Command]?

        func subcommand(named word: String) -> Command? {
            subcommands?.first { $0.commandName == word || ($0.aliases ?? []).contains(word) }
        }

        /// The option or flag `token` names (`--name`, `--name=value`, `-n`).
        func argument(spelled token: String) -> Argument? {
            let spelling = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            return arguments?.first { $0.kind != .positional && $0.spellings.contains(spelling) }
        }

        var capturesPassthrough: Bool {
            arguments?.contains(where: \.capturesPassthrough) ?? false
        }
    }

    var command: Command

    /// The grammar of `rv`, or `nil` if ArgumentParser stops describing it
    /// (help then falls through to ArgumentParser's own page).
    static let rv: CommandGrammar? = {
        do {
            _ = try RV.parseAsRoot(["--experimental-dump-help"])
        } catch {
            return decode(Data(RV.fullMessage(for: error).utf8))
        }
        return nil
    }()

    /// The grammar in `dump`, or `nil` if it does not decode.
    static func decode(_ dump: Data) -> CommandGrammar? {
        try? JSONDecoder().decode(CommandGrammar.self, from: dump)
    }
}

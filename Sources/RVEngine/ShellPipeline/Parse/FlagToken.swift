/// C1 shared flag grammar: structural classification of one argv word.
///
/// Every flag idiom in the engine reduces to these shapes: the `--`
/// terminator, `--long`/`--long=value`, clustered shorts (`-rf`), lone `-`,
/// single-dash `-name=value`, and plain positionals. Multi-letter
/// single-dash words (`find -name`) classify as `.shorts` and are recovered
/// via `singleDashWord`, matching today's dual reading (clusters in git/fs
/// parsers, words in `find` handling).
///
/// `classify` is purely structural: it never consumes neighboring words.
/// `ShellPipeline.scanFlags` builds the value-taking scan on top of it.
public enum FlagToken: Sendable, Hashable, Equatable {
    /// A plain operand. Words after `--` still classify structurally here
    /// only when they carry no dash prefix; consumers split on `.terminator`.
    case positional(String)
    /// The `--` terminator word.
    case terminator
    /// A lone `-` word. Strict parsers reject it; some unwraps keep it.
    case loneDash
    /// `--name` (`value == nil`) or `--name=value` (possibly empty `value`).
    /// An empty attached value stays `""`, never `nil`, because `--source=`
    /// fails today while `--force-with-lease=` passes: the `=` presence and
    /// the emptiness are both load-bearing.
    case long(name: String, value: String?)
    /// `-abc` as one unit (`value == nil` from `classify`). The cluster is
    /// kept whole because strict parsers (`stash`, `rebase`, `reset`)
    /// reject multi-letter clusters outright while others read per-letter;
    /// `scanFlags` fills `value` with the consumed word when any letter
    /// takes a value.
    case shorts(letters: [Character], value: String?)
    /// `-name=value`. No consumer reads these today; all reject them as
    /// unknown flags. Kept flag-like (never positional) to match.
    case shortEquals(name: String, value: String)
    /// A value-taking flag whose value is missing (end of argv) or
    /// dash-led under a `rejectsDashValues` spec. All of today's parsers
    /// fail the whole parse in these cases. Only `scanFlags` produces this.
    case dangling(flag: String)

    /// Structural classification of one argv word. Total: every string maps
    /// to exactly one case, mirroring the `clusteredShorts` /
    /// `hasPrefix("-")` split in the legacy per-command loops.
    public static func classify(_ word: String) -> FlagToken {
        if word == "--" { return .terminator }
        if word == "-" { return .loneDash }
        if word.hasPrefix("--") {
            let rest = String(word.dropFirst(2))
            if let equals = rest.firstIndex(of: "=") {
                return .long(
                    name: String(rest[..<equals]),
                    value: String(rest[rest.index(after: equals)...])
                )
            }
            return .long(name: rest, value: nil)
        }
        if word.hasPrefix("-") {
            if let equals = word.firstIndex(of: "=") {
                return .shortEquals(
                    name: String(word[word.index(after: word.startIndex)..<equals]),
                    value: String(word[word.index(after: equals)...])
                )
            }
            return .shorts(letters: Array(word.dropFirst()), value: nil)
        }
        return .positional(word)
    }

    /// The single-dash-long reading (`-name` -> `"name"`) for commands like
    /// `find` whose predicates are multi-letter single-dash words. Single
    /// shorts and every other case return `nil`.
    public var singleDashWord: String? {
        guard case .shorts(let letters, _) = self, letters.count > 1 else {
            return nil
        }
        return String(letters)
    }
}

/// C1 shell-pipeline vocabulary: one lexical token.
///
/// `lexeme` is the token text with shell quoting removed, exactly as the
/// legacy `tokenizeCommand` produced `decoded`. The quoting flags preserve
/// provenance so later stages (unwrap, parse, classify) can distinguish
/// `git`, `"git"`, and `$'git'` even though their lexemes compare equal.
public struct Token: Sendable, Hashable, Equatable, CustomStringConvertible {
    /// Token text with quotes stripped. Structural newlines surface as `"\n"`.
    public var lexeme: String
    /// True when any part of the token was single-, double-, or ANSI-C quoted.
    public var wasQuoted: Bool
    /// True when any part of the token used ANSI-C (`$'...'`) quoting.
    /// The tokenizer keeps the `$` marker in `lexeme` so ANSI-C payloads
    /// stay visible to later stages; decoding happens downstream.
    public var wasAnsiC: Bool

    public init(lexeme: String, wasQuoted: Bool, wasAnsiC: Bool = false) {
        self.lexeme = lexeme
        self.wasQuoted = wasQuoted
        self.wasAnsiC = wasAnsiC
    }

    /// True for structural newline separators, which the tokenizer emits as
    /// unquoted `"\n"` tokens. A quoted newline (e.g. `"\n"`) shares the
    /// lexeme but is data, not a separator.
    public var isNewline: Bool {
        lexeme == "\n" && wasQuoted == false && wasAnsiC == false
    }

    /// True when the lexeme carries command-substitution syntax that later
    /// stages must not treat as plain data.
    public var containsInlineCode: Bool {
        lexeme.contains("$(") || lexeme.contains("`")
    }

    public var description: String { lexeme }
}

extension ShellPipeline {
    /// C1 shell-pipeline vocabulary: one lexical token.
    ///
    /// `lexeme` is the token text with shell quoting removed, exactly as the
    /// legacy `tokenizeCommand` produced `decoded`. The quoting flags preserve
    /// provenance so later stages (unwrap, parse, classify) can distinguish
    /// `git`, `"git"`, and `$'git'` even though their lexemes compare equal.
    public struct Token: Sendable, Hashable, CustomStringConvertible {
        /// Token text with quotes stripped. Structural newlines surface as `"\n"`.
        public var lexeme: String
        /// True when any part of the token was single-, double-, or ANSI-C quoted.
        public var wasQuoted: Bool
        /// True when any part of the token used ANSI-C (`$'...'`) quoting.
        /// The tokenizer keeps the `$` marker in `lexeme` so ANSI-C payloads
        /// stay visible to later stages; decoding happens downstream.
        public var wasAnsiC: Bool
        /// True when the token carries shell redirect-out structure: either
        /// the raw word holds an unquoted `>` (glued `hi>"/tmp/eve"`,
        /// `2>"/tmp/eve"`) or it is the target word after a bare redirect-out
        /// operator (`> "/tmp/eve"`). Computed from raw quote positions at
        /// tokenize time, so quoted `>` data (`"a>b"`) stays unmarked. Masking
        /// must never hide these: the writers pass needs the exact target.
        public var isRedirectStructural: Bool

        /// Creates a token; `wasAnsiC` implies `wasQuoted`, which is normalized here.
        public init(lexeme: String, wasQuoted: Bool, wasAnsiC: Bool = false, isRedirectStructural: Bool = false) {
            self.lexeme = lexeme
            self.wasQuoted = wasQuoted || wasAnsiC
            self.wasAnsiC = wasAnsiC
            self.isRedirectStructural = isRedirectStructural
        }

        /// True for structural newline separators, which the tokenizer emits as
        /// unquoted `"\n"` tokens. A quoted newline (e.g. `"\n"`) shares the
        /// lexeme but is data, not a separator.
        public var isNewline: Bool {
            lexeme == "\n" && wasQuoted == false && wasAnsiC == false
        }

        /// Lexeme-shape heuristic: true when the lexeme text contains `$(`
        /// or a backtick. Quoted payloads (e.g. `'$(x)'`, `$'...'`) still
        /// return true, so callers must check `wasQuoted`/`wasAnsiC` before
        /// treating a hit as code. `${...}` expansion is not covered.
        public var containsInlineCode: Bool {
            lexeme.contains("$(") || lexeme.contains("`")
        }

        public var description: String { lexeme }
    }
}

extension ShellPipeline.Token: CustomDebugStringConvertible {
    public var debugDescription: String {
        "Token(lexeme: \(lexeme.debugDescription), wasQuoted: \(wasQuoted), wasAnsiC: \(wasAnsiC))"
    }
}

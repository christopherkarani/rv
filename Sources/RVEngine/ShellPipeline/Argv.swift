/// C1 shell-pipeline vocabulary: a single command's typed command line.
///
/// `Argv` replaces ad-hoc `[String]` threading between pipeline stages.
/// `program` is argv0 and `args` the ordered operands; `redacted` marks the
/// indices into `args` whose values are data (commit messages, patterns,
/// payloads) rather than structure, so renderers can mask them without
/// changing the parsed shape.
public struct Argv: Sendable, Hashable, Equatable {
    /// The invoked program (argv0), e.g. `"rm"`.
    public var program: String
    /// Ordered arguments following the program.
    public var args: [String]
    /// Indices into `args` whose values are redacted data.
    public var redacted: Set<Int>

    public init(program: String, args: [String] = [], redacted: Set<Int> = []) {
        self.program = program
        self.args = args
        self.redacted = redacted.filter { $0 >= 0 && $0 < args.count }
    }

    /// Builds an `Argv` from one segment's tokens. Structural newlines are
    /// skipped; the first word becomes `program` and the rest `args` with no
    /// redaction marks. Returns `nil` when no words remain.
    public init?(tokens: [Token]) {
        let words = tokens.filter { $0.isNewline == false }
        guard let head = words.first else { return nil }
        self.program = head.lexeme
        self.args = words.dropFirst().map(\.lexeme)
        self.redacted = []
    }

    /// Full command line in argv order: `[program] + args`.
    public var fullCommand: [String] {
        [program] + args
    }

    /// True when the argument at `index` carries a redaction mark.
    public func isRedacted(at index: Int) -> Bool {
        redacted.contains(index)
    }

    /// Marks the argument at `index` as redacted data. Out-of-range indices
    /// are ignored so total parsers never trap on untrusted input.
    public mutating func markRedacted(at index: Int) {
        guard args.indices.contains(index) else { return }
        redacted.insert(index)
    }

    /// Copy of `self` with the argument at `index` marked redacted.
    public func markingRedacted(at index: Int) -> Argv {
        var copy = self
        copy.markRedacted(at: index)
        return copy
    }
}

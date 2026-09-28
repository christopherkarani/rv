/// C1 shell-pipeline vocabulary: a single command's typed command line.
///
/// `Argv` replaces ad-hoc `[String]` threading between pipeline stages.
/// `program` is argv0 and `args` the ordered operands; `redacted` marks the
/// indices into `args` whose values are data (commit messages, patterns,
/// payloads) rather than structure, so renderers can mask them without
/// changing the parsed shape.
///
/// This is the parsed form of one command. `RVDomain.ShellCommand` carries
/// the raw, unparsed command string; tokenizing and segmenting it yields
/// one `Argv` per command.
public struct Argv: Sendable, Hashable {
    /// The invoked program (argv0), e.g. `"rm"`.
    public var program: String
    /// Ordered arguments following the program.
    ///
    /// Mutating `args` prunes redaction marks that no longer index an
    /// argument, preserving the subset invariant.
    public var args: [String] {
        didSet {
            redacted = redacted.filter { args.indices.contains($0) }
        }
    }
    /// Indices into `args` whose values are redacted data.
    ///
    /// `markRedacted(at:)` is the sole writer, keeping `redacted` a subset
    /// of `args.indices` (see also the `args` prune on mutation).
    public private(set) var redacted: Set<Int>

    /// Creates an argv; out-of-range `redacted` indices are dropped so the
    /// subset invariant holds.
    public init(program: String, args: [String] = [], redacted: Set<Int> = []) {
        self.program = program
        self.args = args
        self.redacted = redacted.filter { $0 >= 0 && $0 < args.count }
    }

    /// Builds an `Argv` from the first segment's tokens: words are consumed
    /// up to (not including) the first structural newline, so multi-segment
    /// input never merges into one command. The first word becomes `program`
    /// and the rest `args` with no redaction marks. Returns `nil` when no
    /// words precede the first newline.
    public init?(tokens: [ShellPipeline.Token]) {
        var words: [String] = []
        words.reserveCapacity(tokens.count)
        for token in tokens {
            if token.isNewline { break }
            words.append(token.lexeme)
        }
        guard let head = words.first else { return nil }
        self.program = head
        self.args = Array(words.dropFirst())
        self.redacted = []
    }

    /// Full command line in argv order: `[program] + args`.
    ///
    /// Values are unmasked: redaction marks are metadata only. Renderers
    /// must mask before display; a masked view lands with the renderer ticket.
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

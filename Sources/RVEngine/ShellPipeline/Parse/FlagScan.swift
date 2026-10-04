/// C1 shared flag grammar: value-taking scan over `Argv`.
///
/// Centralizes the three idioms every per-command loop repeats: `--long`
/// (bare or `=attached`), clustered shorts with per-letter meaning, and
/// next-word value consumption (`-m <msg>`, `--mode <mode>`).
///
/// The scan is deliberately shallow about `--`: it yields `.terminator` as
/// a first-class event and keeps classifying afterwards, because today's
/// consumers disagree — most split positionals there, `clean` skips it and
/// keeps parsing flags, and `push`/`stash`-family reject it as an unknown
/// flag. Each consumer interprets the event its own way (T3b).
extension ShellPipeline {
    /// Scans `argv.args` left to right, consuming value words per `spec`.
    ///
    /// A pending value takes the immediate next word verbatim — even `--`
    /// or a dash-led word — matching the legacy loops, which check the
    /// pending/expect flag before the terminator/flag tests. Only a
    /// `rejectsDashValues` spec turns a dash-led value word into
    /// `.dangling` (today's `checkout -b` / `switch -c` behavior).
    ///
    /// Value shorts consume the rest of their own cluster first
    /// (`touch -tSTAMP` reads `STAMP`, exactly like getopt); only a bare
    /// taker (`-t` alone) consumes the next word. Longs resolve unique
    /// prefixes against the spec's universe before the takes-value test,
    /// matching getopt_long abbreviation (`tar --extr` reads `--extract`);
    /// the resolved name is what parsers match.
    public static func scanFlags(
        _ argv: Argv,
        valueSpec spec: FlagValueSpec = .none
    ) -> [FlagToken] {
        var out: [FlagToken] = []
        out.reserveCapacity(argv.args.count)
        var index = 0
        while index < argv.args.count {
            let word = argv.args[index]
            let token = FlagToken.classify(word)
            switch token {
            case .long(let name, let attached):
                let resolved = spec.resolveLong(name)
                let event: FlagToken = .long(name: resolved, value: attached)
                if spec.takesValue(event) {
                    index = consumeValue(
                        into: &out, words: argv.args, at: index,
                        spec: spec, flag: word,
                        make: { .long(name: resolved, value: $0) }
                    )
                } else {
                    out.append(event)
                    index += 1
                }
            case .shorts(let letters, _):
                if let split = spec.splitShortValue(letters) {
                    index = consumeShortValue(
                        split,
                        into: &out, words: argv.args, at: index,
                        spec: spec, flag: word
                    )
                } else {
                    out.append(token)
                    index += 1
                }
            case .shortEquals(let name, let value):
                if let taken = spec.shortEqualsValue(name: name, value: value) {
                    out.append(taken)
                } else {
                    out.append(token)
                }
                index += 1
            case .positional, .terminator, .loneDash, .dangling:
                out.append(token)
                index += 1
            }
        }
        return out
    }

    /// Appends the value-taking `flag` event and returns the next index:
    /// past the consumed word on success, past only the flag on `.dangling`
    /// so the rejected word is classified normally next (today's parsers
    /// fail the whole parse at the dangling flag either way).
    private static func consumeValue(
        into out: inout [FlagToken],
        words: [String],
        at index: Int,
        spec: FlagValueSpec,
        flag: String,
        make: (String) -> FlagToken
    ) -> Int {
        guard index + 1 < words.count else {
            out.append(.dangling(flag: flag))
            return index + 1
        }
        let candidate = words[index + 1]
        guard spec.consumesValueWord(candidate) else {
            out.append(.dangling(flag: flag))
            return index + 1
        }
        out.append(make(candidate))
        return index + 2
    }

    /// Appends one short-cluster value event: attached rest wins (getopt
    /// reads `-tSTAMP` as `STAMP` without touching the next word); only a
    /// bare taker consumes the next word. The emitted letters stop at the
    /// taker — the consumed rest is a value, never flags — so parsers keep
    /// matching letters against their short sets.
    private static func consumeShortValue(
        _ split: FlagValueSpec.ShortSplit,
        into out: inout [FlagToken],
        words: [String],
        at index: Int,
        spec: FlagValueSpec,
        flag: String
    ) -> Int {
        if split.attached.isEmpty == false {
            out.append(.shorts(letters: split.kept, value: split.attached))
            return index + 1
        }
        return consumeValue(
            into: &out, words: words, at: index,
            spec: spec, flag: flag,
            make: { .shorts(letters: split.kept, value: $0) }
        )
    }
}

/// Which flags consume the following argv word as their value.
public struct FlagValueSpec: Sendable, Hashable {
    /// Cluster letters that take a value (`touch -t`, `mkdir -m`).
    /// The first taker in a cluster consumes the rest of that cluster when
    /// non-empty, else the next word — exactly like getopt.
    public var valueShorts: Set<Character>
    /// Bare long names (without `--`) that take a value (`--mode`, `--date`).
    /// The `=attached` form never consumes.
    public var valueLongs: Set<String>
    /// Bare long names the verb accepts without a value, for unique-prefix
    /// resolution only (`rm --rec` reads `--recursive`). Never consumed.
    public var knownLongs: Set<String>
    /// When true, a dash-led value word is rejected (`.dangling`) instead
    /// of consumed. Only the branch-name takers behave this way today:
    /// `checkout` (`-b`/`-B`/`--branch`/`--orphan`) and `switch`
    /// (`-c`/`-C`/`--create`/`--force-create`).
    public var rejectsDashValues: Bool

    public init(
        valueShorts: Set<Character> = [],
        valueLongs: Set<String> = [],
        knownLongs: Set<String> = [],
        rejectsDashValues: Bool = false
    ) {
        self.valueShorts = valueShorts
        self.valueLongs = valueLongs
        self.knownLongs = knownLongs
        self.rejectsDashValues = rejectsDashValues
    }

    /// No flag takes a value; every word classifies structurally.
    public static let none = FlagValueSpec()

    /// Whether no flag takes a value: the scan classifies purely
    /// structurally and consumes nothing, so post-`--` events can be
    /// recovered verbatim. (`rejectsDashValues` is inert without takers.)
    public var isValueFree: Bool {
        valueShorts.isEmpty && valueLongs.isEmpty
    }

    /// Whether a structurally classified token takes the next argv word as
    /// its value. Attached longs (`--mode=x`) never consume; bare
    /// value-longs do, resolved first. For clusters use `splitShortValue`:
    /// a taker with attached rest is self-contained and consumes nothing.
    /// Shared by `scanFlags` and the filesystem `--` pre-split so the two
    /// readings cannot desync when consumption rules change.
    public func takesValue(_ token: FlagToken) -> Bool {
        switch token {
        case .long(let name, nil) where valueLongs.contains(resolveLong(name)):
            return true
        case .shorts(let letters, _):
            guard let split = splitShortValue(letters) else {
                return false
            }
            return split.attached.isEmpty
        default:
            return false
        }
    }

    /// Whether a pending value consumes `word`: any word, unless this spec
    /// rejects dash-led values (`.dangling` instead).
    public func consumesValueWord(_ word: String) -> Bool {
        rejectsDashValues == false || word.hasPrefix("-") == false
    }

    /// A cluster's value split: the letters to keep (through the first
    /// taker) plus the attached rest the taker consumes. Nil when no
    /// letter takes a value.
    public struct ShortSplit: Sendable, Hashable {
        public var kept: [Character]
        public var attached: String
    }

    /// Splits `letters` at the first value-taking short, mirroring getopt's
    /// left-to-right walk: the first taker consumes everything after it.
    public func splitShortValue(_ letters: [Character]) -> ShortSplit? {
        guard let taker = letters.firstIndex(where: valueShorts.contains) else {
            return nil
        }
        let after = letters.index(after: taker)
        return ShortSplit(
            kept: Array(letters[...taker]),
            attached: String(letters[after...])
        )
    }

    /// Reads a `-name=value` word: the first value-taking short in `name`
    /// consumes the rest of the name plus `=value` (getopt reads `-t=x` as
    /// value `=x`). Nil when no letter takes a value — the tool errors on
    /// the `=`, so callers keep the word flag-like and parsers reject it.
    public func shortEqualsValue(name: String, value: String) -> FlagToken? {
        let letters = Array(name)
        guard let taker = letters.firstIndex(where: valueShorts.contains) else {
            return nil
        }
        let after = letters.index(after: taker)
        return .shorts(
            letters: Array(letters[...taker]),
            value: String(letters[after...]) + "=" + value
        )
    }

    /// Resolves `name` against the spec's long universe (exact first, then
    /// the unique prefix), matching getopt_long abbreviation. Zero or
    /// several matches return `name` unchanged: the tool errors on unknown
    /// and ambiguous spellings, so parsers keep rejecting them.
    /// `help`/`version` stay unresolved by design (see `scanFlags`).
    public func resolveLong(_ name: String) -> String {
        if valueLongs.contains(name) || knownLongs.contains(name) {
            return name
        }
        var match: String?
        for candidate in valueLongs.union(knownLongs) {
            guard candidate.hasPrefix(name) else { continue }
            guard match == nil else { return name }
            match = candidate
        }
        return match ?? name
    }
}

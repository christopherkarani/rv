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
    public static func scanFlags(
        _ argv: Argv,
        values spec: FlagValueSpec = .none
    ) -> [FlagToken] {
        var out: [FlagToken] = []
        out.reserveCapacity(argv.args.count)
        var index = 0
        while index < argv.args.count {
            let word = argv.args[index]
            let token = FlagToken.classify(word)
            switch token {
            case .long(let name, _):
                if spec.takesValue(token) {
                    index = consumeValue(
                        into: &out, words: argv.args, at: index,
                        spec: spec, flag: word,
                        make: { .long(name: name, value: $0) }
                    )
                } else {
                    out.append(token)
                    index += 1
                }
            case .shorts(let letters, _):
                if spec.takesValue(token) {
                    index = consumeValue(
                        into: &out, words: argv.args, at: index,
                        spec: spec, flag: word,
                        make: { .shorts(letters: letters, value: $0) }
                    )
                } else {
                    out.append(token)
                    index += 1
                }
            case .positional, .terminator, .loneDash, .shortEquals, .dangling:
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
}

/// Which flags consume the following argv word as their value.
public struct FlagValueSpec: Sendable, Hashable {
    /// Cluster letters that take a value (`touch -t`, `mkdir -m`).
    /// One word is consumed per cluster containing any of these, matching
    /// the legacy expect-flag loops.
    public var valueShorts: Set<Character>
    /// Bare long names (without `--`) that take a value (`--mode`, `--date`).
    /// The `=attached` form never consumes.
    public var valueLongs: Set<String>
    /// When true, a dash-led value word is rejected (`.dangling`) instead
    /// of consumed. Only the branch-name takers behave this way today:
    /// `checkout` (`-b`/`-B`/`--branch`/`--orphan`) and `switch`
    /// (`-c`/`-C`/`--create`/`--force-create`).
    public var rejectsDashValues: Bool

    public init(
        valueShorts: Set<Character> = [],
        valueLongs: Set<String> = [],
        rejectsDashValues: Bool = false
    ) {
        self.valueShorts = valueShorts
        self.valueLongs = valueLongs
        self.rejectsDashValues = rejectsDashValues
    }

    /// No flag takes a value; every word classifies structurally.
    public static let none = FlagValueSpec()

    /// Whether a structurally classified token takes the next argv word as
    /// its value. Attached longs (`--mode=x`) never consume; bare
    /// value-longs and any cluster containing a value-short do. Shared by
    /// `scanFlags` and the filesystem `--` pre-split so the two readings
    /// cannot desync when consumption rules change.
    public func takesValue(_ token: FlagToken) -> Bool {
        switch token {
        case .long(let name, nil) where valueLongs.contains(name):
            return true
        case .shorts(let letters, _) where letters.contains(where: valueShorts.contains):
            return true
        default:
            return false
        }
    }

    /// Whether a pending value consumes `word`: any word, unless this spec
    /// rejects dash-led values (`.dangling` instead).
    public func consumesValueWord(_ word: String) -> Bool {
        rejectsDashValues == false || word.hasPrefix("-") == false
    }
}

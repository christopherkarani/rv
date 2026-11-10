import RVDomain

// MARK: - Step 8B P10c: statically-bound file writers

/// Parsers for copy-like writer verbs (`cp`, `tee`, `install`, `ln`, `rsync`,
/// `tar`, `curl -o`, `dd of=`). Previously every one of these fell through to
/// `parseRedirectOnly` and evaluated as no-action (ALLOW) even when writing
/// outside the repository. Each parser extracts the destination operand(s) so
/// the normal inside/outside scope rules apply; routine inside-repo use
/// (`cp a b`, `tar -xzf vendor.tar.gz`, `curl -o build/out.json URL`) parses
/// and stays automatic.
///
/// Soundness rules shared by every parser here:
/// - Unknown SHORT flags fail the parse (nil): getopt-style tools exit
///   non-zero on an unknown short, so nothing executes and allow is correct.
/// - Longs resolve unique prefixes first (getopt_long abbreviation):
///   exact-or-unique reads the tool's flag, ambiguous-or-unknown keeps
///   the legacy skip/candidate path the tool's error makes sound.
/// - `-x=y` walks the cluster: a value-led word consumes its `=` rest
///   like getopt, while a bare cluster with `=` fails like the tool.
/// - Conflicted shorts (value on one platform, bare on the other)
///   consume attached rest only, never the next word; each platform's
///   reading stays sound (exact on one, over-approximate on the other).
/// - Unknown `=`-longs are skipped: the attached value cannot desync the
///   operand scan, so destination extraction stays exact.
/// - Unknown bare longs record their neighbor as a candidate destination and
///   continue: a real-but-unlisted value-taking long would otherwise desync
///   the scan into a miss; the candidate turns that into (rare) fail-closed
///   noise instead. `--no-*` negations are bare by GNU convention.
/// - When a bare-vs-value call is uncertain, count-gated verbs (`cp`, `mv`,
///   `ln`, `install`) treat the flag as bare (a non-destination value is
///   never written, so under-consumption is safe) while `rsync` treats it as
///   value-taking (over-consumption is safe there because even a single
///   remaining operand is evaluated as the destination).
/// - `--help`/`--version` return nil: the tool prints and writes nothing.
/// - Redirects never reach these parsers: the dispatcher strips them
///   before the scan and unions their destinations after it
///   (`WriterRedirectFold`), so each parser here returns only its own
///   destinations on redirect-stripped argv.
///
/// Deliberately out of scope: dynamic writers (`python -c`, `node -e`,
/// `bash -c`, `rsync -e 'cmd'`, `tar --to-command` excepted as unbounded).
/// Their file effects are Turing-complete; they are bounded by the workspace
/// sandbox (process confinement), not the static layer — the same standing
/// property as every other opaque-exec shape. `tar` exec-flags and remote
/// rsync destinations fail closed as `unboundedWriteSentinel` instead.

/// Sentinel path standing in for a write whose destination cannot be bounded
/// statically: `tar -x -P` (absolute members), `tar` exec-flags
/// (`-I`, `--to-command`, ...), remote rsync destinations (`host:path`).
/// Classifies outside the repository, so policy denies. Chosen over an
/// unknown scope because the unprobed world skips the unresolved-filesystem
/// tighten while a `/`-rooted overwrite denies in both worlds.
let unboundedWriteSentinel = "/"

// MARK: - Exact writer-argument scan

/// Result of `scanWriterArgs`: operands in order, values per value-taking
/// flag (shorts keyed by letter, longs by bare name), candidate destinations
/// from unknown bare longs, bare-flag hits, and failure/help signals.
struct WriterScan {
    var operands: [String] = []
    var flagValues: [String: [String]] = [:]
    var candidates: [String] = []
    var bareShortHits: Set<Character> = []
    var bareLongHits: Set<String> = []
    var sawHelp = false
    var failed = false
}

/// Exact getopt-ish scan, as a thin policy layer over `FlagToken` events.
/// Grammar mechanics (long unique-prefix resolution, cluster splits, `--`
/// handling, value consumption) come from `FlagToken`/`FlagValueSpec`;
/// unknown-flag soundness (candidates, conflicted shorts, help/version,
/// `--no-*`) stays in `WriterPolicy`. See the file header for the rules.
func scanWriterArgs(
    _ args: [String],
    valueShorts: Set<Character>,
    valueLongs: Set<String>,
    bareShorts: Set<Character>,
    bareLongs: Set<String>,
    conflictedShorts: Set<Character> = []
) -> WriterScan {
    WriterPolicy.fold(
        args,
        config: WriterVerbConfig(
            valueShorts: valueShorts,
            valueLongs: valueLongs,
            bareShorts: bareShorts,
            bareLongs: bareLongs,
            conflictedShorts: conflictedShorts
        )
    )
}

/// Resolves `name` against a writer verb's long universe (exact first, then
/// the unique prefix), matching getopt_long abbreviation. `help`/`version`
/// resolve too: they never write, so `sawHelp` stays sound whether the
/// tool abbreviates or errors. Zero or several matches return `name`.
/// Delegates to the single long-resolution site in `FlagValueSpec`.
func resolveWriterLong(
    _ name: String,
    valueLongs: Set<String>,
    bareLongs: Set<String>
) -> String {
    FlagValueSpec(
        valueLongs: valueLongs,
        knownLongs: bareLongs.union(["help", "version"])
    ).resolveLong(name)
}

/// Writer-verb policy configuration: the shared flag grammar (`spec`) plus
/// the writer's bare-flag policy sets. `help`/`version` join the spec's
/// long universe so resolution matches `resolveWriterLong` (exact or
/// unique-prefix, never a write); conflicted shorts become attached-only
/// takers (attached rest only, never the next word).
struct WriterVerbConfig: Sendable, Hashable {
    var spec: FlagValueSpec
    var bareShorts: Set<Character>
    var bareLongs: Set<String>

    init(
        valueShorts: Set<Character>,
        valueLongs: Set<String>,
        bareShorts: Set<Character>,
        bareLongs: Set<String>,
        conflictedShorts: Set<Character> = []
    ) {
        self.spec = FlagValueSpec(
            valueShorts: valueShorts,
            valueLongs: valueLongs,
            knownLongs: bareLongs.union(["help", "version"]),
            attachedOnlyShorts: conflictedShorts
        )
        self.bareShorts = bareShorts
        self.bareLongs = bareLongs
    }
}

/// Thin writer-soundness policy over `FlagToken` events. Each word classifies
/// to one event; value consumption advances the word walk, so unknown bare
/// longs still record their verbatim neighbor word as a candidate (a
/// resolved/consumed event alone could not reproduce that spelling).
enum WriterPolicy {
    static func fold(_ words: [String], config: WriterVerbConfig) -> WriterScan {
        var scan = WriterScan()
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            switch FlagToken.classify(word) {
            case .terminator:
                scan.operands += words[words.index(after: index)...]
                return scan
            case .long(let name, let attached):
                foldLong(
                    name: name,
                    attached: attached,
                    words: words,
                    index: &index,
                    config: config,
                    scan: &scan
                )
            case .shorts(let letters, _):
                if let split = config.spec.splitShortValue(letters) {
                    if foldSplit(
                        kept: split.kept,
                        attached: split.attached,
                        words: words,
                        index: &index,
                        config: config,
                        scan: &scan
                    ) == false {
                        return scan
                    }
                } else if foldBareLetters(letters, config: config, scan: &scan) == false {
                    return scan
                } else {
                    words.formIndex(after: &index)
                }
            case .shortEquals(let name, let value):
                guard let taken = config.spec.shortEqualsValue(name: name, value: value),
                    case .shorts(let kept, let attached?) = taken
                else {
                    // No value-taker in the cluster: the tool errors on
                    // the `=`, so failing the parse is sound.
                    scan.failed = true
                    return scan
                }
                if foldSplit(
                    kept: kept,
                    attached: attached,
                    words: words,
                    index: &index,
                    config: config,
                    scan: &scan
                ) == false {
                    return scan
                }
            case .positional(let operand):
                scan.operands.append(operand)
                words.formIndex(after: &index)
            case .loneDash:
                scan.operands.append(word)
                words.formIndex(after: &index)
            case .dangling:
                // `classify` never produces this; fail closed if it ever does.
                scan.failed = true
                return scan
            }
        }
        return scan
    }

    /// Folds one `--long`/`--long=value` event. `=`-longs never consume;
    /// bare value-longs consume the next word verbatim (pending wins over
    /// `--`, exactly like getopt); unknown bare longs record their verbatim
    /// neighbor as a candidate. Always advances past the flag; a consumed
    /// value advances once more. A dangling value long fails but keeps
    /// scanning, matching the legacy loop.
    private static func foldLong(
        name: String,
        attached: String?,
        words: [String],
        index: inout Array<String>.Index,
        config: WriterVerbConfig,
        scan: inout WriterScan
    ) {
        let resolved = config.spec.resolveLong(name)
        if let attached {
            if config.spec.valueLongs.contains(resolved) {
                scan.flagValues[resolved, default: []].append(attached)
            } else if resolved == "help" || resolved == "version" {
                scan.sawHelp = true
            }
            // else: unknown =-long — attached value, no desync; skip.
            words.formIndex(after: &index)
            return
        }
        if config.spec.valueLongs.contains(resolved) {
            guard index + 1 < words.endIndex,
                config.spec.consumesValueWord(words[words.index(after: index)])
            else {
                scan.failed = true
                words.formIndex(after: &index)
                return
            }
            words.formIndex(after: &index)
            scan.flagValues[resolved, default: []].append(words[index])
        } else if resolved == "help" || resolved == "version" {
            scan.sawHelp = true
        } else if config.bareLongs.contains(resolved) || name.hasPrefix("no-") {
            scan.bareLongHits.insert(resolved)
        } else if index + 1 < words.endIndex {
            // Unknown bare long: a real-but-unlisted value-taker would eat
            // its neighbor, so the neighbor is also evaluated as a
            // destination.
            scan.candidates.append(words[words.index(after: index)])
        }
        words.formIndex(after: &index)
    }

    /// Folds an all-bare cluster (no value-taking letter). False when a
    /// letter is unknown, stopping the whole scan. Attached-only letters
    /// read bare here: with a non-empty rest they would have split.
    private static func foldBareLetters(
        _ letters: [Character],
        config: WriterVerbConfig,
        scan: inout WriterScan
    ) -> Bool {
        for letter in letters {
            guard config.bareShorts.contains(letter)
                || config.spec.attachedOnlyShorts.contains(letter)
            else {
                scan.failed = true
                return false
            }
            scan.bareShortHits.insert(letter)
        }
        return true
    }

    /// Folds one cluster split: letters before the taker must be bare, and
    /// the taker (a value or attached-only short) consumes its attached
    /// rest or the next word verbatim. False when a letter is unknown or
    /// the value dangles, stopping the whole scan.
    private static func foldSplit(
        kept: [Character],
        attached: String,
        words: [String],
        index: inout Array<String>.Index,
        config: WriterVerbConfig,
        scan: inout WriterScan
    ) -> Bool {
        for letter in kept.dropLast() {
            guard config.bareShorts.contains(letter) else {
                scan.failed = true
                return false
            }
            scan.bareShortHits.insert(letter)
        }
        guard let taker = kept.last else {
            scan.failed = true
            return false
        }
        if attached.isEmpty == false {
            scan.flagValues[String(taker), default: []].append(attached)
            words.formIndex(after: &index)
            return true
        }
        // Attached-only takers always arrive with a non-empty rest (both
        // `splitShortValue` and `shortEqualsValue` guarantee it), so this
        // next-word branch only serves plain value shorts.
        guard index + 1 < words.endIndex,
            config.spec.consumesValueWord(words[words.index(after: index)])
        else {
            scan.failed = true
            return false
        }
        words.formIndex(after: &index)
        scan.flagValues[String(taker), default: []].append(words[index])
        words.formIndex(after: &index)
        return true
    }
}

func writerParsed(
    operation: FilesystemOperation,
    paths: [String]
) -> ParsedFilesystemCommand? {
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: operation,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

// MARK: - P10e9: wget / iconv / unzip / split / sed / sqlite3 / ditto / gzip / zip

/// Extracts output values for getopt-style output flags without a main scan:
/// only exact output flags collect, so unknown flags cannot desync it (a
/// missed output would need the tool to accept a flag the parser rejects,
/// and getopt tools error there instead). Longs resolve unique prefixes via
/// `resolveWriterLong` (ambiguous abbreviations error in the tool, so
/// skipping them is sound). `-` (stdout) is skipped: shell redirects are
/// the fold's claim. Stops at `--`. `skipShorts`/`skipLongs` are consumed and
/// ignored so their values cannot misread as flags.
func extractOutputValues(
    _ args: [String],
    shorts: Set<Character>,
    longs: Set<String>,
    skipShorts: Set<Character> = [],
    skipLongs: Set<String> = []
) -> [String] {
    var out: [String] = []
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        if word == "--" { break }
        if word.hasPrefix("--"), word.count > 2 {
            let rest = String(word.dropFirst(2))
            if let equals = rest.firstIndex(of: "=") {
                let name = resolveWriterLong(
                    String(rest[..<equals]), valueLongs: longs, bareLongs: []
                )
                if longs.contains(name) {
                    let value = String(rest[rest.index(after: equals)...])
                    if value != "-" { out.append(value) }
                }
            } else {
                let name = resolveWriterLong(rest, valueLongs: longs, bareLongs: [])
                if longs.contains(name) {
                    if index + 1 < args.endIndex {
                        args.formIndex(after: &index)
                        if args[index] != "-" { out.append(args[index]) }
                    }
                } else if skipLongs.contains(rest) {
                    if index + 1 < args.endIndex { args.formIndex(after: &index) }
                }
            }
            args.formIndex(after: &index)
            continue
        }
        if word.hasPrefix("-"), word.count > 1, word != "-" {
            let letters = Array(word.dropFirst())
            var letterIndex = letters.startIndex
            while letterIndex < letters.endIndex {
                let letter = letters[letterIndex]
                if shorts.contains(letter) {
                    let rest = String(letters[letters.index(after: letterIndex)...])
                    if rest.isEmpty == false {
                        if rest != "-" { out.append(rest) }
                    } else if index + 1 < args.endIndex {
                        args.formIndex(after: &index)
                        if args[index] != "-" { out.append(args[index]) }
                    }
                    break
                }
                if skipShorts.contains(letter) {
                    let rest = letters[letters.index(after: letterIndex)...]
                    if rest.isEmpty, index + 1 < args.endIndex {
                        args.formIndex(after: &index)
                    }
                    break
                }
                letters.formIndex(after: &letterIndex)
            }
            args.formIndex(after: &index)
            continue
        }
        args.formIndex(after: &index)
    }
    return out
}

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
/// - Redirect targets are UNIONED with writer destinations: `tee /tmp/a >
///   /tmp/b` writes both files.
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

/// Exact getopt-ish scan. Value shorts consume the rest of their cluster when
/// non-empty (`-oFILE`) or the next word (`-o FILE`); value longs consume via
/// `=` or the next word. Longs resolve unique prefixes (getopt_long
/// abbreviation); `-x=y` walks the cluster so a value-led word consumes its
/// `=` rest exactly like the tool. See the file header for unknown-flag
/// soundness.
func scanWriterArgs(
    _ args: [String],
    valueShorts: Set<Character>,
    valueLongs: Set<String>,
    bareShorts: Set<Character>,
    bareLongs: Set<String>,
    conflictedShorts: Set<Character> = []
) -> WriterScan {
    var scan = WriterScan()
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        if word == "--" {
            scan.operands += args[args.index(after: index)...]
            break
        }
        if word.hasPrefix("--"), word.count > 2 {
            scanLongWriterFlag(
                String(word.dropFirst(2)),
                args: args,
                index: &index,
                valueLongs: valueLongs,
                bareLongs: bareLongs,
                scan: &scan
            )
            continue
        }
        if word.hasPrefix("-"), word.count > 1 {
            if scanShortWriterCluster(
                word,
                args: args,
                index: &index,
                valueShorts: valueShorts,
                bareShorts: bareShorts,
                conflictedShorts: conflictedShorts,
                scan: &scan
            ) == false {
                break
            }
            continue
        }
        scan.operands.append(word)
        args.formIndex(after: &index)
    }
    return scan
}

/// Resolves `name` against a writer verb's long universe (exact first, then
/// the unique prefix), matching getopt_long abbreviation. `help`/`version`
/// resolve too: they never write, so `sawHelp` stays sound whether the
/// tool abbreviates or errors. Zero or several matches return `name`.
func resolveWriterLong(
    _ name: String,
    valueLongs: Set<String>,
    bareLongs: Set<String>
) -> String {
    if valueLongs.contains(name) || bareLongs.contains(name)
        || name == "help" || name == "version"
    {
        return name
    }
    var match: String?
    for candidate in valueLongs.union(bareLongs).union(["help", "version"]) {
        guard candidate.hasPrefix(name) else { continue }
        guard match == nil else { return name }
        match = candidate
    }
    return match ?? name
}

private func scanLongWriterFlag(
    _ rest: String,
    args: [String],
    index: inout Array<String>.Index,
    valueLongs: Set<String>,
    bareLongs: Set<String>,
    scan: inout WriterScan
) {
    if let equals = rest.firstIndex(of: "=") {
        let name = resolveWriterLong(
            String(rest[..<equals]),
            valueLongs: valueLongs,
            bareLongs: bareLongs
        )
        if valueLongs.contains(name) {
            scan.flagValues[name, default: []]
                .append(String(rest[rest.index(after: equals)...]))
        } else if name == "help" || name == "version" {
            scan.sawHelp = true
        }
        // else: unknown =-long — attached value, no desync; skip.
        args.formIndex(after: &index)
        return
    }
    let name = resolveWriterLong(rest, valueLongs: valueLongs, bareLongs: bareLongs)
    if valueLongs.contains(name) {
        guard index + 1 < args.endIndex else {
            // Dangling value long: fail, but still advance past the flag —
            // the caller re-reads the word at `index`, so returning here
            // without advancing would spin forever.
            scan.failed = true
            args.formIndex(after: &index)
            return
        }
        args.formIndex(after: &index)
        scan.flagValues[name, default: []].append(args[index])
    } else if name == "help" || name == "version" {
        scan.sawHelp = true
    } else if bareLongs.contains(name) || rest.hasPrefix("no-") {
        scan.bareLongHits.insert(name)
    } else if index + 1 < args.endIndex {
        // Unknown bare long: a real-but-unlisted value-taker would eat its
        // neighbor, so the neighbor is also evaluated as a destination.
        scan.candidates.append(args[args.index(after: index)])
    }
    args.formIndex(after: &index)
}

/// Scans one short cluster. False when the cluster fails the parse.
/// Conflicted shorts (value on one platform, bare on the other) consume
/// attached rest but never the next word: `cp -Sx` reads suffix `x`
/// (GNU-exact; BSD errors), while separate `-S x` stays bare (BSD-exact;
/// GNU's suffix becomes a dropped source, which keeps the destination).
private func scanShortWriterCluster(
    _ word: String,
    args: [String],
    index: inout Array<String>.Index,
    valueShorts: Set<Character>,
    bareShorts: Set<Character>,
    conflictedShorts: Set<Character>,
    scan: inout WriterScan
) -> Bool {
    let letters = Array(word.dropFirst())
    var letterIndex = letters.startIndex
    while letterIndex < letters.endIndex {
        let letter = letters[letterIndex]
        if valueShorts.contains(letter) {
            let rest = String(letters[letters.index(after: letterIndex)...])
            if rest.isEmpty == false {
                scan.flagValues[String(letter), default: []].append(rest)
            } else {
                guard index + 1 < args.endIndex else {
                    scan.failed = true
                    return false
                }
                args.formIndex(after: &index)
                scan.flagValues[String(letter), default: []].append(args[index])
            }
            break
        }
        if conflictedShorts.contains(letter) {
            let rest = String(letters[letters.index(after: letterIndex)...])
            if rest.isEmpty == false {
                scan.flagValues[String(letter), default: []].append(rest)
                break
            }
            scan.bareShortHits.insert(letter)
            letters.formIndex(after: &letterIndex)
            continue
        }
        guard bareShorts.contains(letter) else {
            // Unknown short — `=` included: a pure bare cluster with `=`
            // errors in the tool, so failing the parse is sound, while a
            // value-led cluster consumed its `=` rest above, like getopt.
            scan.failed = true
            return false
        }
        scan.bareShortHits.insert(letter)
        letters.formIndex(after: &letterIndex)
    }
    args.formIndex(after: &index)
    return true
}

// MARK: - -t/--target-directory pre-scan

/// Extracts every `-t DIR` / `--target-directory=DIR` override shared by `cp`,
/// `mv`, `ln`, and `install`, returning all overrides plus the argv with the
/// `-t` words removed for the main scan. Every override evaluates (rather
/// than last-wins) so interleaved exact, abbreviated, and repeated `-t`
/// forms stay sound without positional tracking; the tool writes the last
/// while the parser over-approximates. Attached (`-tDIR`, `-vtDIR`,
/// `-t=DIR`) and separate (`-t DIR`) short forms both parse; a dangling `-t`
/// is left in place so the main scan fails it (the tool errors). A `t` after
/// a value-taking short is that short's value, not `-t` (`mv -StDIR` reads
/// suffix `tDIR`). A `t` after a conflicted short is ambiguous: BSD reads
/// `-t` while GNU reads the conflicted short's value, so callers keep the
/// last operand as well (`overrideAmbiguous`). Stops at `--`: later words
/// are operands even when they spell `-t`.
func extractTargetDirectory(
    _ args: [String],
    valueShorts: Set<Character> = [],
    conflictedShorts: Set<Character> = []
) -> (overrides: [String], reduced: [String], overrideAmbiguous: Bool) {
    var overrides: [String] = []
    var reduced: [String] = []
    var overrideAmbiguous = false
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        if word == "--" {
            reduced += args[index...]
            break
        }
        if word == "--target-directory" {
            if index + 1 < args.endIndex {
                args.formIndex(after: &index)
                overrides.append(args[index])
            } else {
                reduced.append(word)
            }
            args.formIndex(after: &index)
            continue
        }
        if word.hasPrefix("--target-directory=") {
            overrides.append(String(word.dropFirst("--target-directory=".count)))
            args.formIndex(after: &index)
            continue
        }
        if isShortClusterWord(word),
            let tpos = targetDirectoryTPosition(word, valueShorts: valueShorts)
        {
            let letters = Array(word.dropFirst())
            if letters[..<tpos].contains(where: conflictedShorts.contains) {
                overrideAmbiguous = true
            }
            let before = String(letters[..<tpos])
            let after = String(letters[letters.index(after: tpos)...])
            if before.isEmpty == false {
                reduced.append("-" + before)
            }
            if after.isEmpty == false {
                overrides.append(after)
            } else if index + 1 < args.endIndex {
                args.formIndex(after: &index)
                overrides.append(args[index])
            } else {
                reduced.append("-t")
            }
            args.formIndex(after: &index)
            continue
        }
        reduced.append(word)
        args.formIndex(after: &index)
    }
    return (overrides, reduced, overrideAmbiguous)
}

/// Position of the first `t` that reads as `-t`: a `t` preceded by a
/// value-taking short is that short's attached value (`-StDIR` reads
/// suffix `tDIR`), never a flag. Conflicted shorts (BSD-bare/GNU-value)
/// do not block: the main scan re-reads them, and collecting the `-t`
/// value as well over-approximates both tools soundly.
private func targetDirectoryTPosition(
    _ word: String,
    valueShorts: Set<Character>
) -> Array<Character>.Index? {
    let letters = Array(word.dropFirst())
    guard let tpos = letters.firstIndex(of: "t") else {
        return nil
    }
    if letters[..<tpos].contains(where: valueShorts.contains) {
        return nil
    }
    return tpos
}

/// Collects BSD `install -D destdir` values (every occurrence evaluates).
/// GNU `-D` is bare (create-leading), so the words stay in place for the
/// main scan, which reads `-D` bare: each platform's reading stays sound
/// (BSD collects the write-prefix, GNU over-approximates a source).
func extractInstallDValues(
    _ args: [String],
    valueShorts: Set<Character>
) -> [String] {
    var values: [String] = []
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        if word == "--" {
            break
        }
        if isShortClusterWord(word) {
            let letters = Array(word.dropFirst())
            if let dpos = letters.firstIndex(of: "D"),
                letters[..<dpos].contains(where: valueShorts.contains) == false
            {
                let rest = String(letters[letters.index(after: dpos)...])
                if rest.isEmpty == false {
                    values.append(rest)
                } else if index + 1 < args.endIndex {
                    values.append(args[args.index(after: index)])
                }
            }
        }
        args.formIndex(after: &index)
    }
    return values
}

private func isShortClusterWord(_ word: String) -> Bool {
    word.hasPrefix("-") && word.hasPrefix("--") == false && word.count > 1
}

/// Output-redirect destinations united with writer destinations.
func writerRedirectDests(_ argv: Argv) -> [String] {
    parseRedirectOnly(argv)?.paths ?? []
}

/// Removes redirect syntax from writer argv so operators and their targets
/// never pollute the operand scan. Output operators drop with their target
/// (the union re-adds the target); input/heredoc operators drop WITHOUT
/// their target — the target stays an operand, which over-approximates in
/// the fail-closed direction and cannot eat a quoted metachar operand the
/// way target-eating would. Attached input words (`<f`, `<<EOF`) drop whole
/// (their target is inseparable); fd dups/closes drop whole (no file).
func stripWriterRedirectWords(_ args: [String]) -> [String] {
    var clean: [String] = []
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        if isRedirectOperator(word) {
            args.formIndex(after: &index)
            if index < args.endIndex {
                args.formIndex(after: &index)
            }
            continue
        }
        if writerInputSeparators.contains(word) {
            args.formIndex(after: &index)
            continue
        }
        if stripWriterAttachedWord(word) {
            args.formIndex(after: &index)
            continue
        }
        clean.append(word)
        args.formIndex(after: &index)
    }
    return clean
}

private let writerInputSeparators: Set<String> = [
    "<", "<<", "<<-", "<<<", "0<", "1<",
]

private func stripWriterAttachedWord(_ word: String) -> Bool {
    if word.contains(">&") || word.contains("<&") {
        return true
    }
    if word.hasPrefix(">") || word.hasPrefix("<") || word.hasPrefix("&>") {
        return true
    }
    var digits = word.startIndex
    while digits < word.endIndex, word[digits].isNumber {
        word.formIndex(after: &digits)
    }
    if digits > word.startIndex, digits < word.endIndex {
        let next = word[digits]
        if next == ">" || next == "<" {
            return true
        }
    }
    return false
}

private func writerParsed(
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

// MARK: - cp / tee / install / ln

/// `cp` destination: the `-t` overrides, else the last operand. Every other
/// flag keeps the destination where getopt leaves it: `-T` only changes
/// file-vs-directory treatment, `-r`/`-n`/`-u` narrow what lands under it,
/// and `--backup`/`-b`/`-S` add same-directory sidecars. `-S` is conflicted
/// (GNU suffix value, BSD bare): attached rest reads as the suffix, a
/// separate `-S` stays bare, and each platform's destination stays sound.
func parseCp(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (targetDirs, reduced, overrideAmbiguous) = extractTargetDirectory(
        stripWriterRedirectWords(argv.args),
        conflictedShorts: ["S"]
    )
    let scan = scanWriterArgs(
        reduced,
        valueShorts: [],
        valueLongs: ["suffix", "target-directory"],
        bareShorts: cpBareShorts,
        bareLongs: cpBareLongs,
        conflictedShorts: ["S"]
    )
    var dests: [String] = []
    if scan.failed == false, scan.sawHelp == false {
        dests += scan.candidates
        dests += targetDirs
        dests += scan.flagValues["target-directory"] ?? []
        let hasOverride = targetDirs.isEmpty == false
            || scan.flagValues["target-directory"] != nil
        if (hasOverride == false || overrideAmbiguous),
            scan.operands.count >= 2, let last = scan.operands.last
        {
            dests.append(last)
        }
    }
    // Redirects are shell-side: they write even when the verb errors or
    // prints help, so the union survives verb-parse failure.
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseCp(_ args: [String]) -> ParsedFilesystemCommand? {
    parseCp(Argv(program: "cp", args: args))
}

// `-N` is macOS-valid (suppress file flags with `-p`); `-Z` is GNU-only
// (accepted: the tool errors on macOS, so accepting it only
// false-positives). `-S` is bare here (BSD) and conflicted (GNU value).
private let cpBareShorts: Set<Character> = [
    "a", "b", "c", "d", "f", "H", "i", "L", "l", "N", "n", "P", "p",
    "R", "r", "S", "s", "T", "u", "v", "X", "x", "Z",
]

/// Optional-`=` longs (`--preserve`, `--reflink`, ...) are bare: GNU only
/// accepts their values attached, so they never consume a neighbor.
private let cpBareLongs: Set<String> = [
    "archive", "backup", "copy-contents", "no-dereference", "force",
    "interactive", "no-clobber", "dereference", "link", "preserve",
    "reflink", "remove-destination", "symbolic-link", "no-target-directory",
    "update", "verbose", "one-file-system", "parents", "attributes-only",
    "keep-directory-symlink", "debug", "strip-trailing-slashes", "sparse",
    "context",
]

/// `tee` writes every operand (plus stdout). No value flags exist, so the
/// scan is bare-only; a bare `tee` reads stdin to stdout and parses to nil.
func parseTee(_ argv: Argv) -> ParsedFilesystemCommand? {
    let scan = scanWriterArgs(
        stripWriterRedirectWords(argv.args),
        valueShorts: [],
        valueLongs: [],
        bareShorts: ["a", "i", "p"],
        bareLongs: ["append", "ignore-interrupts", "output-error"]
    )
    var dests: [String] = []
    if scan.failed == false, scan.sawHelp == false {
        dests += scan.operands + scan.candidates
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseTee(_ args: [String]) -> ParsedFilesystemCommand? {
    parseTee(Argv(program: "tee", args: args))
}

/// `install` file mode mirrors `cp` (last operand or `-t`); `-d` directory
/// mode creates every operand (under `-t` when given) and parses as `.create`.
/// BSD/GNU shorts diverge three ways: `-D` is a destdir value on BSD but
/// bare (create-leading) on GNU, so a pre-scan collects BSD `-D` values
/// while the main scan reads `-D` bare; `-S`/`-T` are conflicted (GNU
/// value-vs-bare mirrored on BSD), consuming attached rest only. `-M`
/// (BSD metalog file) always evaluates.
func parseInstall(_ argv: Argv) -> ParsedFilesystemCommand? {
    let stripped = stripWriterRedirectWords(argv.args)
    let (targetDirs, reduced, overrideAmbiguous) = extractTargetDirectory(
        stripped,
        valueShorts: installValueShorts,
        conflictedShorts: ["S", "T"]
    )
    let dValues = extractInstallDValues(stripped, valueShorts: installValueShorts)
    let scan = scanWriterArgs(
        reduced,
        valueShorts: installValueShorts,
        valueLongs: ["suffix", "mode", "owner", "group", "strip-program", "target-directory"],
        bareShorts: installBareShorts,
        bareLongs: [
            "backup", "compare", "directory", "create-leading",
            "preserve-timestamps", "strip", "symbolic-link", "verbose",
            "no-target-directory", "context",
        ],
        conflictedShorts: ["S", "T"]
    )
    let directoryMode = scan.failed == false && scan.sawHelp == false
        && (scan.bareShortHits.contains("d") || scan.bareLongHits.contains("directory"))
    var dests: [String] = []
    if scan.failed == false, scan.sawHelp == false {
        dests += scan.candidates
        dests += targetDirs
        dests += scan.flagValues["target-directory"] ?? []
        dests += scan.flagValues["M"] ?? []
        let hasOverride = targetDirs.isEmpty == false
            || scan.flagValues["target-directory"] != nil
        if hasOverride == false || overrideAmbiguous {
            if directoryMode {
                dests += scan.operands
            } else if scan.operands.count >= 2, let last = scan.operands.last {
                dests.append(last)
            }
        }
    }
    // BSD `-D` values survive main-scan failure: the GNU reading may fail
    // the cluster (`-Ddestdir` walks `e` as unknown) while BSD wrote under
    // the destdir. Only `--help`/`--version` drop them (help exits before
    // any install); a failed main scan means at most the GNU tool errored.
    if scan.sawHelp == false {
        dests += dValues
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: directoryMode ? .create : .overwrite, paths: dests)
}

// BSD values (`-B` suffix, `-D` destdir collected by pre-scan, `-f` flags,
// `-h` hash, `-l` linkflags, `-M` metalog) plus shared `-m`/`-o`/`-g`.
// `-D` is deliberately absent: the main scan reads it bare (GNU) while
// the pre-scan collects it (BSD). `-S`/`-T` are conflicted, not values.
private let installValueShorts: Set<Character> = ["B", "f", "g", "h", "l", "M", "m", "o"]

// `-U` is macOS-valid; `-Z` is GNU-only (accepted: the tool errors on
// macOS, so accepting it only false-positives). `-D` is bare here (GNU;
// BSD values come from the pre-scan); `-S`/`-T` are bare here (BSD) and
// conflicted (GNU value/bare mirrored).
private let installBareShorts: Set<Character> = [
    "b", "C", "c", "D", "d", "p", "s", "v", "T", "U", "S", "Z",
]

func parseInstall(_ args: [String]) -> ParsedFilesystemCommand? {
    parseInstall(Argv(program: "install", args: args))
}

/// `ln` destination: the `-t` overrides, else the last operand; a single
/// operand links into the working directory. Parses as `.create`.
func parseLn(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (targetDirs, reduced, overrideAmbiguous) = extractTargetDirectory(
        stripWriterRedirectWords(argv.args),
        valueShorts: ["S"]
    )
    let scan = scanWriterArgs(
        reduced,
        valueShorts: ["S"],
        valueLongs: ["suffix", "target-directory"],
        bareShorts: ["b", "d", "F", "f", "h", "i", "L", "n", "P", "p", "r", "s", "T", "v", "w"],
        bareLongs: [
            "backup", "directory", "force", "interactive", "logical",
            "no-dereference", "physical", "relative", "symbolic", "verbose",
            "no-target-directory", "strip-trailing-slashes",
        ]
    )
    var dests: [String] = []
    if scan.failed == false, scan.sawHelp == false {
        dests += scan.candidates
        dests += targetDirs
        dests += scan.flagValues["target-directory"] ?? []
        let hasOverride = targetDirs.isEmpty == false
            || scan.flagValues["target-directory"] != nil
        if hasOverride == false || overrideAmbiguous {
            if scan.operands.count == 1 {
                dests.append(".")
            } else if scan.operands.count >= 2, let last = scan.operands.last {
                dests.append(last)
            }
        }
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .create, paths: dests)
}

func parseLn(_ args: [String]) -> ParsedFilesystemCommand? {
    parseLn(Argv(program: "ln", args: args))
}

// MARK: - rsync

/// `rsync` destination: the last operand plus auxiliary write locations
/// (`--log-file`, `--write-batch`, `--temp-dir`, `--partial-dir`,
/// `--backup-dir`). A remote destination (`host:path`, `[v6]:path`,
/// `host::module`, `rsync://...`) fails closed as `unboundedWriteSentinel`:
/// a remote write is outside the repository by definition, and its safety
/// cannot be established. `-n` / `--dry-run` / `--list-only` skip the
/// transfer — but `--log-file` and `--write-batch` still write under a
/// dry run, so they collect before the dry-run gate (A-F3, C-F12). `-e`'s
/// value is consumed but ignored: the rsh command executes (opaque-exec,
/// same standing property as `bash -c`) while the transferred destination
/// is still bounded here.
func parseRsync(_ argv: Argv) -> ParsedFilesystemCommand? {
    let scan = scanWriterArgs(
        stripWriterRedirectWords(argv.args),
        valueShorts: ["T", "e", "f", "M", "B"],
        valueLongs: rsyncValueLongs,
        bareShorts: rsyncBareShorts,
        bareLongs: rsyncBareLongs
    )
    var dests: [String] = []
    if scan.failed == false, scan.sawHelp == false {
        dests += scan.flagValues["log-file"] ?? []
        dests += scan.flagValues["write-batch"] ?? []
    }
    if scan.failed == false, scan.sawHelp == false,
        scan.bareShortHits.contains("n") == false,
        scan.bareLongHits.contains("dry-run") == false,
        scan.bareLongHits.contains("list-only") == false
    {
        dests += scan.candidates
        for key in ["T", "temp-dir", "partial-dir", "backup-dir"] {
            dests += scan.flagValues[key] ?? []
        }
        if let last = scan.operands.last {
            dests.append(rsyncLocalOrRemote(last))
        }
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseRsync(_ args: [String]) -> ParsedFilesystemCommand? {
    parseRsync(Argv(program: "rsync", args: args))
}

/// Remote when a colon precedes the first slash (rsync's own rule: `a:b` is
/// `host:path`, while `./a:b` is local) or the operand is an rsync URL.
private func rsyncLocalOrRemote(_ operand: String) -> String {
    if operand.hasPrefix("rsync://") {
        return unboundedWriteSentinel
    }
    let head = operand.prefix(while: { $0 != "/" })
    if head.contains(":") {
        return unboundedWriteSentinel
    }
    return operand
}

// `-f`/`-M`/`-B` take values (filter, remote-option, block-size).
// `-0`/`-d`/`-F` are openrsync-valid (macOS `/usr/bin/rsync`); `-8`,
// `-C`, `-g`, `-I`, `-k`, `-N` are GNU-valid. Accepted everywhere: the
// tool errors where a flag is unknown, so accepting only false-positives.
private let rsyncBareShorts: Set<Character> = [
    "a", "b", "c", "D", "E", "F", "H", "h", "I", "i", "J", "K", "k",
    "l", "L", "m", "N", "n", "O", "o", "p", "P", "q", "R", "r", "s",
    "S", "t", "u", "v", "W", "w", "x", "X", "y", "z", "A", "C", "d",
    "U", "V", "Z", "g", "0", "4", "6", "8",
]

private let rsyncBareLongs: Set<String> = [
    "archive", "verbose", "quiet", "checksum", "recursive", "dirs", "links",
    "perms", "executability", "owner", "group", "devices", "specials",
    "times", "update", "inplace", "append", "append-verify", "sparse",
    "whole-file", "one-file-system", "existing", "ignore-existing",
    "remove-source-files", "delete", "delete-before", "delete-during",
    "delete-after", "delete-delay", "delete-excluded", "ignore-errors",
    "force", "partial", "delay-updates", "prune-empty-dirs", "fuzzy",
    "compress", "size-only", "blocking-io", "stats", "progress",
    "human-readable", "itemize-changes", "numeric-ids", "ignore-times",
    "delete-missing-args", "from0", "old-dirs", "omit-dir-times",
    "omit-link-times", "crtimes", "only-write-batch", "ipv4", "ipv6",
    "8-bit-output", "list-only", "dry-run", "super", "fake-super",
    "mkpath", "protect-args", "copy-links", "keep-dirlinks",
    "copy-dirlinks", "copy-unsafe-links", "safe-links", "munge-links",
    "hard-links", "msgs2stderr", "backup", "atimes", "acls", "xattrs",
    "relative", "implied-dirs", "old-args", "secluded-args", "trust-sender",
    "del", "cache", "cvs-exclude",
]

// MARK: - tar

/// `tar` destination by mode. Create/append/update/delete write the `-f`
/// archive; extract writes the `-C` directory, `--one-top-level`, or the
/// working directory; `--recursive-unlink` extract parses as a recursive
/// `.delete` (it empties the tree first); list/compare parse to nil. Old-style
/// bundles (`tar xvf f.tar`) parse only as the FIRST word, matching tar.
/// `-P` extract, exec-flags (`-I`, `--to-command`, `--info-script`,
/// `--new-volume-script`, `--rsh-command`, `exec=...` checkpoint actions),
/// and the `-g`/`-G` snapshot file fail closed or collect as documented below.
/// `--volno-file`/`--index-file` sidecars collect; bare `--incremental`
/// reads the working directory. Longs resolve unique prefixes (both tars
/// abbreviate). Unknown shorts are SKIPPED (not failed) while every
/// value-taking short consumes: member operands never feed a destination,
/// so only `-f`/`-C`/`-g` values matter and they are consumed exactly like
/// the tool consumes them; an erroring invocation can only fail closed.
func parseTar(_ argv: Argv) -> ParsedFilesystemCommand? {
    guard let scan = tarScan(argv.args) else {
        // The tool errored or printed help, but shell-side redirects still
        // wrote; the union is verb-independent.
        return writerParsed(operation: .overwrite, paths: writerRedirectDests(argv))
    }
    return tarDecide(scan, argv: argv)
}

private func tarScan(_ args: [String]) -> TarScan? {
    var scan = TarScan()
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        if word == "--" {
            break
        }
        if word.hasPrefix("--"), word.count > 2 {
            guard let ok = tarLong(String(word.dropFirst(2)), args: args, index: &index, scan: &scan), ok else {
                return nil
            }
            continue
        }
        if word.hasPrefix("-"), word.count > 1 {
            // No `=` rejection: a value-led cluster consumes its `=` rest
            // (`-f=x.tar` reads archive `=x.tar`, exactly like the tool),
            // while a bare cluster with `=` fails when the walk meets a
            // mode conflict or skips into a mode-empty reading the tool's
            // error makes sound.
            if tarCluster(Array(word.dropFirst()), args: args, index: &index, scan: &scan) == false {
                return nil
            }
            continue
        }
        if index == args.startIndex, tarLooksLikeBundle(word) {
            if tarCluster(Array(word), args: args, index: &index, scan: &scan) == false {
                return nil
            }
            continue
        }
        args.formIndex(after: &index)
    }
    return scan
}

func parseTar(_ args: [String]) -> ParsedFilesystemCommand? {
    parseTar(Argv(program: "tar", args: args))
}

private struct TarScan {
    var mode: Character?
    var archive: String?
    var changeDir: String?
    var oneTopLevel: String?
    var snapshotFiles: [String] = []
    var absoluteNames = false
    var unboundedExec = false
    var recursiveUnlink = false
}

private func tarLooksLikeBundle(_ word: String) -> Bool {
    // GNU attempts an old-style bundle read on any non-dash first word
    // (erroring on option-chars like `/`); attached values can carry any
    // bytes (`cf=/tmp/x.tar` reads archive `=/tmp/x.tar`), so only the
    // mode-letter trigger gates the bundle read. Non-bundle words are
    // members, which never feed a destination.
    guard word.isEmpty == false,
        word.contains(where: { "cxrutdAD".contains($0) })
    else {
        return false
    }
    return true
}

/// One dashed cluster or old-style bundle. False only when the tool errors.
/// Unknown shorts skip (member operands never feed a destination), but every
/// value-taking short consumes: attached letters after a skipped taker would
/// otherwise re-read as mode letters (`-cHustar` mis-set update mode).
private func tarCluster(
    _ letters: [Character],
    args: [String],
    index: inout Array<String>.Index,
    scan: inout TarScan
) -> Bool {
    var letterIndex = letters.startIndex
    while letterIndex < letters.endIndex {
        let letter = letters[letterIndex]
        switch letter {
        case "c", "x", "r", "u", "t", "d", "A", "D":
            if let have = scan.mode, have != letter {
                return false
            }
            scan.mode = letter
        case "f", "C", "g", "G", "H", "L", "V", "K", "N", "T", "X":
            let rest = String(letters[letters.index(after: letterIndex)...])
            if rest.isEmpty == false {
                tarRecordValue(letter, value: rest, scan: &scan)
            } else {
                guard index + 1 < args.endIndex else {
                    return false
                }
                args.formIndex(after: &index)
                tarRecordValue(letter, value: args[index], scan: &scan)
            }
            // The value consumed the rest of the cluster (`-cf/tmp/x` must
            // not re-read `/tmp/x` as flags); the letter walk ends here.
            letterIndex = letters.endIndex
            continue
        case "P":
            scan.absoluteNames = true
        case "I", "F":
            scan.unboundedExec = true
            // The program/script value is an ignored member-word; only the
            // first word bundle-matches, so no consumption desync is possible.
            letterIndex = letters.endIndex
            continue
        default:
            break
        }
        letters.formIndex(after: &letterIndex)
    }
    args.formIndex(after: &index)
    return true
}

private func tarRecordValue(_ letter: Character, value: String, scan: inout TarScan) {
    switch letter {
    case "f":
        scan.archive = value
    case "C":
        scan.changeDir = value
    case "g", "G":
        scan.snapshotFiles.append(value)
    default:
        // Non-location values (`-H` format, `-V` label, `-T` file list,
        // `-X` excludes, `-K`/`-N` selectors, `-L` tape length): consumed
        // so attached mode letters cannot re-read, never collected.
        break
    }
}

/// One `--long`: true to continue, false when the tool errors, nil for
/// `--help`/`--version` (the caller maps both non-true outcomes to nil).
private func tarLong(
    _ rest: String,
    args: [String],
    index: inout Array<String>.Index,
    scan: inout TarScan
) -> Bool? {
    let name: String
    let attached: String?
    if let equals = rest.firstIndex(of: "=") {
        name = String(rest[..<equals])
        attached = String(rest[rest.index(after: equals)...])
    } else {
        name = rest
        attached = nil
    }
    func nextWord() -> String? {
        guard index + 1 < args.endIndex else { return nil }
        args.formIndex(after: &index)
        return args[index]
    }
    switch resolveTarLong(name) {
    case "file":
        guard let value = attached ?? nextWord() else { return false }
        scan.archive = value
    case "directory":
        guard let value = attached ?? nextWord() else { return false }
        scan.changeDir = value
    case "volno-file", "index-file":
        // Written sidecars (multi-volume number, file index): collected
        // like snapshot files.
        guard let value = attached ?? nextWord() else { return false }
        scan.snapshotFiles.append(value)
    case "incremental":
        // Bare `--incremental` errors on create without `--listed-incremental`
        // and reads on extract, but a snapshot write cannot be ruled out;
        // the working directory evaluates silently inside the repository.
        scan.snapshotFiles.append(".")
    case "checkpoint":
        // Print-every-N: consumed (a number) so the value never re-reads
        // as flags, never collected.
        guard attached ?? nextWord() != nil else { return false }
    case "one-top-level":
        // Optional-`=` only: a bare `--one-top-level` extracts under the
        // working directory, so only the attached form names a directory.
        if let dir = attached {
            scan.oneTopLevel = dir
        }
    case "listed-incremental", "snapshot-file":
        guard let value = attached ?? nextWord() else { return false }
        scan.snapshotFiles.append(value)
    case "create":
        if tarSetMode("c", scan: &scan) == false { return false }
    case "extract", "get":
        if tarSetMode("x", scan: &scan) == false { return false }
    case "append":
        if tarSetMode("r", scan: &scan) == false { return false }
    case "update":
        if tarSetMode("u", scan: &scan) == false { return false }
    case "list":
        if tarSetMode("t", scan: &scan) == false { return false }
    case "compare", "diff":
        if tarSetMode("d", scan: &scan) == false { return false }
    case "delete":
        if tarSetMode("D", scan: &scan) == false { return false }
    case "catenate", "concatenate":
        if tarSetMode("A", scan: &scan) == false { return false }
    case "test-label":
        if tarSetMode("t", scan: &scan) == false { return false }
    case "absolute-names":
        scan.absoluteNames = true
    case "recursive-unlink":
        scan.recursiveUnlink = true
    case "use-compress-program", "info-script", "new-volume-script",
        "rsh-command", "to-command":
        scan.unboundedExec = true
    case "checkpoint-action":
        let value = attached ?? ((index + 1 < args.endIndex) ? args[index + 1] : nil)
        if value?.contains("exec") == true {
            scan.unboundedExec = true
        }
    case "help", "version":
        return nil
    default:
        break
    }
    args.formIndex(after: &index)
    return true
}

/// Resolves a tar long against the handled universe (exact first, then the
/// unique prefix), matching getopt_long abbreviation on both GNU and BSD
/// tar. Unhandled longs (format selectors, member matchers, owner/mode
/// metadata) skip: they never name a write location, and skipping leaves
/// the tool's other words for the cases above.
private func resolveTarLong(_ name: String) -> String {
    if tarLongUniverse.contains(name) {
        return name
    }
    var match: String?
    for candidate in tarLongUniverse {
        guard candidate.hasPrefix(name) else { continue }
        guard match == nil else { return name }
        match = candidate
    }
    return match ?? name
}

private let tarLongUniverse: Set<String> = [
    "file", "directory", "one-top-level", "listed-incremental",
    "snapshot-file", "create", "extract", "get", "append", "update",
    "list", "compare", "diff", "delete", "catenate", "concatenate",
    "test-label", "absolute-names", "recursive-unlink",
    "use-compress-program", "info-script", "new-volume-script",
    "rsh-command", "to-command", "checkpoint-action", "volno-file",
    "index-file", "incremental", "checkpoint",
]

private func tarSetMode(_ mode: Character, scan: inout TarScan) -> Bool {
    if let have = scan.mode, have != mode {
        return false
    }
    scan.mode = mode
    return true
}

private func tarDecide(_ scan: TarScan, argv: Argv) -> ParsedFilesystemCommand? {
    if scan.unboundedExec {
        return writerParsed(
            operation: .overwrite,
            paths: [unboundedWriteSentinel] + writerRedirectDests(argv)
        )
    }
    guard let mode = scan.mode else {
        return writerParsed(operation: .overwrite, paths: writerRedirectDests(argv))
    }
    switch mode {
    case "t", "d":
        // List/compare read, but their stdout redirect still wrote.
        return writerParsed(operation: .overwrite, paths: writerRedirectDests(argv))
    case "c", "r", "u", "A", "D":
        var dests = scan.snapshotFiles + writerRedirectDests(argv)
        if let archive = scan.archive {
            dests.append(archive)
        }
        return writerParsed(operation: .overwrite, paths: dests)
    case "x":
        if scan.absoluteNames {
            return writerParsed(
                operation: .overwrite,
                paths: [unboundedWriteSentinel] + writerRedirectDests(argv)
            )
        }
        var dirs = scan.snapshotFiles + writerRedirectDests(argv)
        if let dir = scan.changeDir {
            dirs.append(dir)
        }
        if let top = scan.oneTopLevel {
            dirs.append(top)
        }
        if scan.changeDir == nil, scan.oneTopLevel == nil {
            dirs.append(".")
        }
        if scan.recursiveUnlink {
            guard dirs.isEmpty == false else { return nil }
            return ParsedFilesystemCommand(
                operation: .delete,
                paths: dirs,
                recursive: true,
                force: true,
                mode: nil
            )
        }
        return writerParsed(operation: .overwrite, paths: dirs)
    default:
        return nil
    }
}

// MARK: - curl

/// `curl` file destinations: `-o`/`--output`, `-O`/`--remote-name` /
/// `--remote-name-all` (into `--output-dir` or the working directory),
/// `-D`/`--dump-header`, `--trace`/`--trace-ascii`, `-c`/`--cookie-jar`,
/// `--hsts`, `--stderr`, `--etag-save`, `--alt-svc`, `--libcurl`,
/// `--dump-ca-embed`, `--ssl-keylogfile`, and `-K`/`--config` (a config
/// file can name any option, so it reads as unbounded). Longs resolve
/// unique prefixes (curl abbreviates); `-o=x` consumes its `=` rest like
/// getopt. Every other flag is skipped: curl's remaining surface reads,
/// prints, or tunes the transfer, and skipping is sound here because only
/// the collected values feed a destination — an unknown flag either errors
/// the tool (fail-closed noise) or runs with its destinations still
/// extracted. A `-` value means stdout.
func parseCurl(_ argv: Argv) -> ParsedFilesystemCommand? {
    var dests: [String] = []
    var outputDir: String?
    var remoteName = false
    var index = argv.args.startIndex
    while index < argv.args.endIndex {
        let word = argv.args[index]
        if word == "--" {
            break
        }
        if word.hasPrefix("--"), word.count > 2 {
            let rest = String(word.dropFirst(2))
            let rawName: String
            let attached: String?
            if let equals = rest.firstIndex(of: "=") {
                rawName = String(rest[..<equals])
                attached = String(rest[rest.index(after: equals)...])
            } else {
                rawName = rest
                attached = nil
            }
            switch resolveCurlLong(rawName) {
            case "output", "dump-header", "trace", "trace-ascii",
                "cookie-jar", "hsts", "stderr", "etag-save", "alt-svc",
                "libcurl", "dump-ca-embed", "ssl-keylogfile":
                if let value = attached ?? curlNextWord(argv.args, &index) {
                    dests.append(value)
                }
            case "output-dir":
                if let value = attached ?? curlNextWord(argv.args, &index) {
                    outputDir = value
                }
            case "remote-name", "remote-name-all":
                remoteName = true
            case "config":
                // A config file can name any curl option (including `-o`
                // anywhere), and its content is unbounded statically.
                if attached ?? curlNextWord(argv.args, &index) != nil {
                    dests.append(unboundedWriteSentinel)
                }
            case "help", "version", "manual":
                return writerParsed(operation: .overwrite, paths: writerRedirectDests(argv))
            default:
                break
            }
            argv.args.formIndex(after: &index)
            continue
        }
        if word.hasPrefix("-"), word.count > 1 {
            let letters = Array(word.dropFirst())
            var letterIndex = letters.startIndex
            while letterIndex < letters.endIndex {
                let letter = letters[letterIndex]
                switch letter {
                case "o", "D", "c":
                    let rest = String(letters[letters.index(after: letterIndex)...])
                    if rest.isEmpty == false {
                        dests.append(rest)
                    } else if let value = curlNextWord(argv.args, &index) {
                        dests.append(value)
                    }
                    letterIndex = letters.endIndex
                case "K":
                    // `-K`/`--config` content is unbounded (see above).
                    let rest = String(letters[letters.index(after: letterIndex)...])
                    if rest.isEmpty == false || curlNextWord(argv.args, &index) != nil {
                        dests.append(unboundedWriteSentinel)
                    }
                    letterIndex = letters.endIndex
                case "O":
                    remoteName = true
                    letters.formIndex(after: &letterIndex)
                default:
                    letters.formIndex(after: &letterIndex)
                }
            }
            argv.args.formIndex(after: &index)
            continue
        }
        argv.args.formIndex(after: &index)
    }
    if remoteName {
        dests.append(outputDir ?? ".")
    }
    dests += writerRedirectDests(argv)
    dests.removeAll { $0 == "-" }
    return writerParsed(operation: .overwrite, paths: dests)
}

/// Resolves a curl long against the write-flag universe (exact first, then
/// the unique prefix), matching curl's getopt_long abbreviation. Unknown
/// longs skip: curl's remaining flags read, print, or tune the transfer,
/// and none names a file curl writes. `help`/`version`/`manual` stay
/// exact-only: an abbreviated help still prints (nothing runs), so the
/// parsed destinations can only false-positive.
private func resolveCurlLong(_ name: String) -> String {
    if curlWriteLongs.contains(name) {
        return name
    }
    var match: String?
    for candidate in curlWriteLongs {
        guard candidate.hasPrefix(name) else { continue }
        guard match == nil else { return name }
        match = candidate
    }
    return match ?? name
}

private let curlWriteLongs: Set<String> = [
    "output", "output-dir", "remote-name", "remote-name-all",
    "dump-header", "trace", "trace-ascii", "cookie-jar", "hsts",
    "stderr", "etag-save", "alt-svc", "libcurl", "dump-ca-embed",
    "ssl-keylogfile", "config",
]

func parseCurl(_ args: [String]) -> ParsedFilesystemCommand? {
    parseCurl(Argv(program: "curl", args: args))
}

/// Next word, or nil at end of argv (the tool errors; the permissive curl
/// scan skips instead of failing).
private func curlNextWord(_ args: [String], _ index: inout Array<String>.Index) -> String? {
    guard index + 1 < args.endIndex else { return nil }
    args.formIndex(after: &index)
    return args[index]
}

// MARK: - dd

/// `dd` destination: every `of=FILE` operand (last wins in the tool;
/// over-approximating with all of them is sound). Operands without `=`,
/// dash-words, and `--help`/`--version` are handled per the header: unknown
/// operands error the tool, so ignoring them while still collecting `of=`
/// can only fail closed.
func parseDd(_ argv: Argv) -> ParsedFilesystemCommand? {
    var dests: [String] = []
    for word in argv.args {
        if word == "--help" || word == "--version" {
            return writerParsed(operation: .overwrite, paths: writerRedirectDests(argv))
        }
        guard word.hasPrefix("-") == false,
            let equals = word.firstIndex(of: "=")
        else {
            continue
        }
        if word[..<equals] == "of" {
            let target = String(word[word.index(after: equals)...])
            // `of=-` and `of=/dev/std{out,err,in}` write the process's own
            // stdio, not a file — except when the shell redirected that fd,
            // which the redirect union below already collects.
            if ddStdioTargets.contains(target) == false {
                dests.append(target)
            }
        }
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

private let ddStdioTargets: Set<String> = [
    "-", "/dev/stdout", "/dev/stderr", "/dev/stdin",
]

func parseDd(_ args: [String]) -> ParsedFilesystemCommand? {
    parseDd(Argv(program: "dd", args: args))
}

/// Generous by design (see the file header): for rsync an uncertain flag
/// takes a value, because over-consumption stays sound via the
/// single-operand destination rule while under-consumption would miss.
private let rsyncValueLongs: Set<String> = [
    "temp-dir", "partial-dir", "backup-dir", "log-file", "exclude",
    "include", "filter", "files-from", "rsh", "rsync-path", "address",
    "port", "timeout", "contimeout", "bwlimit", "chmod", "chown", "usermap",
    "groupmap", "suffix", "out-format", "log-format", "checksum-choice",
    "compress-choice", "protocol", "max-size", "min-size", "max-delete",
    "block-size", "write-batch", "read-batch", "outbuf", "sockopts",
    "checksum-seed", "max-alloc", "copy-dest", "link-dest",
    "compare-dest", "exclude-from", "include-from", "filter-merge",
    "iconv", "remote-option", "skip-compress", "copy-as", "compress-level",
]

// MARK: - P10e9: wget / iconv / unzip / split / sed / sqlite3 / ditto / gzip / zip

/// Extracts output values for getopt-style output flags without a main scan:
/// only exact output flags collect, so unknown flags cannot desync it (a
/// missed output would need the tool to accept a flag the parser rejects,
/// and getopt tools error there instead). Longs resolve unique prefixes via
/// `resolveWriterLong` (ambiguous abbreviations error in the tool, so
/// skipping them is sound). `-` (stdout) is skipped: shell redirects union
/// separately. Stops at `--`. `skipShorts`/`skipLongs` are consumed and
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

/// `wget` writes `-O file` / `-P dir` (+ `--output-document`,
/// `--directory-prefix`) and the `-o` / `-a` log files. Default fetches land
/// under the cwd (inside, unclaimed). Residual: `-e` executes wgetrc
/// commands, so `-e logfile=/tmp/x` redirects output opaquely (same class as
/// every other embedded-language residual).
func parseWget(_ argv: Argv) -> ParsedFilesystemCommand? {
    var dests = extractOutputValues(
        stripWriterRedirectWords(argv.args),
        shorts: ["O", "P", "o", "a"],
        longs: ["output-document", "directory-prefix", "output-file", "append-output"],
        skipShorts: ["e"],
        skipLongs: ["execute"]
    )
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseWget(_ args: [String]) -> ParsedFilesystemCommand? {
    parseWget(Argv(program: "wget", args: args))
}

/// `iconv` writes `-o file` (`--output`) or stdout. Operands are inputs
/// (reads, never claimed).
func parseIconv(_ argv: Argv) -> ParsedFilesystemCommand? {
    var dests = extractOutputValues(
        stripWriterRedirectWords(argv.args),
        shorts: ["o"],
        longs: ["output"],
        skipShorts: ["f", "t"],
        skipLongs: ["from-code", "to-code"]
    )
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseIconv(_ args: [String]) -> ParsedFilesystemCommand? {
    parseIconv(Argv(program: "iconv", args: args))
}

/// `unzip` extracts under the cwd or `-d dir`. Like `tar -x`, a default
/// extraction claims `"."` so `cd`-tracked outside cwds fail closed (M-05);
/// `.` resolves against the tracked cwd, so inside extraction stays quiet.
/// List/test/pipe modes never touch the disk and claim nothing. Residual:
/// archive-slip (`../../`) depends on member names, unknowable statically.
func parseUnzip(_ argv: Argv) -> ParsedFilesystemCommand? {
    let args = stripWriterRedirectWords(argv.args)
    let redirectDests = writerRedirectDests(argv)
    if unzipListsOnly(args) || unzipArchiveOperands(args).isEmpty {
        return writerParsed(operation: .overwrite, paths: redirectDests)
    }
    var dests = extractOutputValues(args, shorts: ["d"], longs: [])
    if dests.isEmpty {
        dests.append(".")
    }
    dests += redirectDests
    return writerParsed(operation: .overwrite, paths: dests)
}

/// True when `unzip` only lists, tests, or pipes members (`-l`, `-Z`, `-t`,
/// `-p`, `-c`, `-v`, `-h`): nothing is written, so no extraction root is
/// claimed. Scans clusters (`-Zl`) since unzip takes getopt-style shorts;
/// `-d` consumes its value (attached or next word), so a directory like
/// `/tmp/x` never misreads as flags.
private func unzipListsOnly(_ args: [String]) -> Bool {
    let query: Set<Character> = ["l", "Z", "t", "p", "c", "v", "h"]
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        if word == "--" { return false }
        guard word.hasPrefix("-"), word.count > 1, word != "-",
            word.hasPrefix("--") == false
        else {
            args.formIndex(after: &index)
            continue
        }
        var consumesNext = false
        let letters = word.dropFirst()
        var letterIndex = letters.startIndex
        while letterIndex < letters.endIndex {
            if letters[letterIndex] == "d" {
                consumesNext = letters.index(after: letterIndex) == letters.endIndex
                break
            }
            if query.contains(letters[letterIndex]) { return true }
            letters.formIndex(after: &letterIndex)
        }
        args.formIndex(after: &index)
        if consumesNext, index < args.endIndex {
            args.formIndex(after: &index)
        }
    }
    return false
}

/// Non-flag operands (the archive plus optional member filters). A bare
/// `unzip` with no operands prints usage and extracts nothing.
private func unzipArchiveOperands(_ args: [String]) -> [String] {
    var operands: [String] = []
    var endOfFlags = false
    for word in args {
        if endOfFlags {
            operands.append(word)
            continue
        }
        if word == "--" {
            endOfFlags = true
            continue
        }
        if word.hasPrefix("-"), word.count > 1, word != "-" { continue }
        operands.append(word)
    }
    return operands
}

func parseUnzip(_ args: [String]) -> ParsedFilesystemCommand? {
    parseUnzip(Argv(program: "unzip", args: args))
}

private let splitValueShorts: Set<Character> = ["a", "b", "C", "l", "n", "t"]

private let splitValueLongs: Set<String> = [
    "suffix-length", "bytes", "lines", "line-bytes", "separator", "filter",
    "additional-suffix", "number",
]

private let splitBareShorts: Set<Character> = [
    "d", "x", "e", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
]

private let splitBareLongs: Set<String> = [
    "numeric-suffixes", "hex-suffixes", "verbose", "elide-empty-files",
]

/// `split [input [prefix]]` writes `prefix*` files, defaulting to `x*`
/// under the cwd. An explicit prefix is claimed; otherwise `.` is claimed
/// (same as `tar -x`) so `cd`-tracked outside cwds fail closed while inside
/// extraction stays quiet (M-05). Residual: `--filter=cmd` pipes chunks to
/// shell code, which writes wherever the command writes (opaque-exec, same
/// as `python -c`).
func parseSplit(_ argv: Argv) -> ParsedFilesystemCommand? {
    let scan = scanWriterArgs(
        stripWriterRedirectWords(argv.args),
        valueShorts: splitValueShorts,
        valueLongs: splitValueLongs,
        bareShorts: splitBareShorts,
        bareLongs: splitBareLongs
    )
    var dests: [String] = []
    if scan.failed == false, scan.sawHelp == false {
        if scan.operands.count >= 2 {
            dests.append(scan.operands[1])
            dests += scan.candidates
        } else {
            dests.append(".")
        }
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseSplit(_ args: [String]) -> ParsedFilesystemCommand? {
    parseSplit(Argv(program: "split", args: args))
}

private let sedValueShorts: Set<Character> = ["e", "f", "l"]

private let sedValueLongs: Set<String> = ["expression", "file", "line-length"]

private let sedBareShorts: Set<Character> = ["n", "r", "E", "u", "z", "s", "h", "V"]

private let sedBareLongs: Set<String> = [
    "in-place", "posix", "quiet", "silent", "regexp-extended", "sandbox",
    "separate", "unbuffered", "follow-symlinks", "debug",
]

/// `sed -i` (or `--in-place[=suffix]`) rewrites its file operands in place;
/// without `-i` sed writes stdout only. `-i` is conflicted (GNU consumes an
/// attached suffix only, never the next word), which keeps the destination
/// sound on both GNU and BSD readings. Files are the operands after the
/// script position (the first operand, unless `-e`/`-f` gave the script).
/// Residuals: `w /tmp/x` inside the script writes without `-i`, and the GNU
/// `e` command executes — both are script-language dataflow, unmodeled.
func parseSed(_ argv: Argv) -> ParsedFilesystemCommand? {
    let stripped = stripWriterRedirectWords(argv.args)
    let scan = scanWriterArgs(
        stripped,
        valueShorts: sedValueShorts,
        valueLongs: sedValueLongs,
        bareShorts: sedBareShorts,
        bareLongs: sedBareLongs,
        conflictedShorts: ["i"]
    )
    var dests: [String] = []
    // The main scan drops bare `=`-longs, so `--in-place=.bak` also needs
    // the marker pre-scan (exact or unique-prefix, either `=` form).
    let inPlaceLong = stripped.contains { word in
        guard word.hasPrefix("--") else { return false }
        let rest = String(word.dropFirst(2))
        let name = rest.contains("=")
            ? String(rest[..<(rest.firstIndex(of: "=")!)])
            : rest
        return resolveWriterLong(name, valueLongs: [], bareLongs: ["in-place"])
            == "in-place"
    }
    if scan.failed == false, scan.sawHelp == false,
        scan.bareShortHits.contains("i") || scan.flagValues["i"] != nil
            || scan.bareLongHits.contains("in-place") || inPlaceLong
    {
        let scriptGiven = scan.flagValues["e"] != nil || scan.flagValues["f"] != nil
            || scan.flagValues["expression"] != nil || scan.flagValues["file"] != nil
        let files = scriptGiven
            ? Array(scan.operands)
            : Array(scan.operands.dropFirst())
        dests += files
        dests += scan.candidates
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseSed(_ args: [String]) -> ParsedFilesystemCommand? {
    parseSed(Argv(program: "sed", args: args))
}

/// sqlite3 single-dash words taking one value (from `sqlite3 --help`).
private let sqliteOneValueWords: Set<String> = [
    "-alg", "-cmd", "-escape", "-init", "-hexkey", "-key", "-maxsize",
    "-newline", "-nonce", "-nullvalue", "-screenwidth", "-separator",
    "-textkey", "-vfs",
]

/// sqlite3 single-dash words taking two values.
private let sqliteTwoValueWords: Set<String> = ["-lookaside", "-pagecache"]

/// sqlite3 bare single-dash words (modes, toggles, queries).
private let sqliteBareWords: Set<String> = [
    "-append", "-bail", "-deserialize", "-ifexists", "-memtrace", "-nofollow",
    "-noinit", "-pcachetrace", "-readonly", "-safe", "-vfstrace",
    "-unsafe-testing", "-ascii", "-batch", "-box", "-column", "-csv", "-echo",
    "-header", "-noheader", "-help", "-html", "-interactive", "-json",
    "-line", "-list", "-markdown", "-quote", "-stats", "-table", "-tabs",
    "-version", "-zip",
]

/// Strips sqlite3's single-dash words (which are not getopt clusters) before
/// the main scan, consuming each value word's values. Returns the reduced
/// argv plus whether `-readonly` was seen (read-only: nothing is claimed).
private func stripSqliteDashWords(_ args: [String]) -> (reduced: [String], readonly: Bool) {
    var reduced: [String] = []
    var readonly = false
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        if word == "--" {
            reduced += args[index...]
            break
        }
        if word == "-readonly" {
            readonly = true
            args.formIndex(after: &index)
            continue
        }
        if sqliteOneValueWords.contains(word) {
            args.formIndex(after: &index)
            if index < args.endIndex { args.formIndex(after: &index) }
            continue
        }
        if sqliteTwoValueWords.contains(word) {
            args.formIndex(after: &index)
            if index < args.endIndex { args.formIndex(after: &index) }
            if index < args.endIndex { args.formIndex(after: &index) }
            continue
        }
        if sqliteBareWords.contains(word) {
            args.formIndex(after: &index)
            continue
        }
        reduced.append(word)
        args.formIndex(after: &index)
    }
    return (reduced, readonly)
}

/// `sqlite3 db ...` opens (and normally writes) the database operand; only
/// the first operand is claimed. `:memory:` databases, read-only URIs, and
/// `-readonly` claim nothing. sqlite3 takes no getopt flags, so after the
/// dash-word strip the main scan runs with empty flag sets: any remaining
/// `-x` fails the parse, and the tool errors there too. Residual: dot
/// commands (`-cmd ".output /tmp/x"`) redirect output opaquely.
func parseSqlite3(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (stripped, readonly) = stripSqliteDashWords(stripWriterRedirectWords(argv.args))
    var dests: [String] = []
    if readonly == false {
        let scan = scanWriterArgs(
            stripped,
            valueShorts: [],
            valueLongs: [],
            bareShorts: [],
            bareLongs: ["readonly"]
        )
        if scan.failed == false, scan.sawHelp == false,
            scan.bareLongHits.contains("readonly") == false,
            let db = scan.operands.first, sqliteDbWrites(db)
        {
            dests.append(db)
            dests += scan.candidates
        }
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseSqlite3(_ args: [String]) -> ParsedFilesystemCommand? {
    parseSqlite3(Argv(program: "sqlite3", args: args))
}

/// True when the database operand names a writable file: `:memory:` and
/// read-only/immutable/memory `file:` URIs return false.
private func sqliteDbWrites(_ db: String) -> Bool {
    if db == ":memory:" { return false }
    guard db.hasPrefix("file:") else { return true }
    let rest = String(db.dropFirst("file:".count))
    if rest.contains(":memory:") { return false }
    guard let query = rest.split(separator: "?", maxSplits: 1).last,
        query.contains("=")
    else {
        return true
    }
    let params = query.split(separator: "&").map { $0.split(separator: "=").map(String.init) }
    for param in params {
        guard param.count == 2 else { continue }
        if param[0] == "mode", param[1] == "ro" || param[1] == "memory" { return false }
        if param[0] == "immutable", param[1] != "0" { return false }
    }
    return true
}

private let dittoBareShorts: Set<Character> = ["v", "V", "X", "c", "z", "j", "x", "k", "h"]

private let dittoValueLongs: Set<String> = [
    "arch", "bom", "zlibCompressionLevel", "keepBinariesList",
    "keepBinariesPattern", "lang", "outBom", "option",
]

private let dittoBareLongs: Set<String> = [
    "keepParent", "keepBinaries", "acl", "extattr", "hfsCompression",
    "preserveHFSCompression", "qtn", "noacl", "nocache", "noclone",
    "noextattr", "nohfsCompression", "nonAtomicCopies", "nopersistRootless",
    "nopreserveHFSCompression", "noqtn", "norsrc", "clone", "help",
]

/// `ditto` (macOS) copies/extracts/archives with the destination as the last
/// operand in every mode (copy, `-c` create, `-x` extract), so only the last
/// operand is claimed. `--outBom` and `--keepBinariesList` name extra output
/// files and are claimed too. ditto takes no value shorts.
func parseDitto(_ argv: Argv) -> ParsedFilesystemCommand? {
    let scan = scanWriterArgs(
        stripWriterRedirectWords(argv.args),
        valueShorts: [],
        valueLongs: dittoValueLongs,
        bareShorts: dittoBareShorts,
        bareLongs: dittoBareLongs
    )
    var dests: [String] = []
    if scan.failed == false, scan.sawHelp == false, scan.operands.count >= 2,
        let last = scan.operands.last, last != "-"
    {
        dests.append(last)
        dests += scan.flagValues["outBom"] ?? []
        dests += scan.flagValues["keepBinariesList"] ?? []
        dests += scan.candidates
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseDitto(_ args: [String]) -> ParsedFilesystemCommand? {
    parseDitto(Argv(program: "ditto", args: args))
}

private let inplaceCompressValueShorts: Set<Character> = ["S", "F", "C", "T", "M", "b"]

private let inplaceCompressValueLongs: Set<String> = [
    "suffix", "format", "check", "threads", "memory", "memlimit",
    "memlimit-compress", "memlimit-decompress", "block-size",
]

private let inplaceCompressBareShorts: Set<Character> = [
    "d", "k", "f", "t", "c", "l", "q", "v", "N", "n", "e", "r", "s", "h", "V",
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
]

private let inplaceCompressBareLongs: Set<String> = [
    "decompress", "keep", "force", "test", "list", "stdout", "to-stdout",
    "quiet", "verbose", "name", "no-name", "recursive", "fast", "best",
    "extreme", "rsyncable", "version", "help",
]

private let inplaceCompressNoWriteShorts: Set<Character> = ["c", "t", "l"]

private let inplaceCompressNoWriteLongs: Set<String> = [
    "stdout", "to-stdout", "test", "list",
]

/// In-place compressors (`gzip`/`gunzip`, `bzip2`/`bunzip2`, `xz`/`unxz`,
/// `compress`/`uncompress`) rewrite each operand in place plus a same-dir
/// sidecar (`.gz`/`.bz2`/`.xz`/`.Z`), so every operand is claimed: the
/// operand's own directory decides the verdict. Stdout (`-c`), test (`-t`),
/// and list (`-l`) modes write no files and claim nothing (shell redirects
/// union separately). `-r` marks the claim recursive.
func parseInplaceCompress(_ argv: Argv) -> ParsedFilesystemCommand? {
    let scan = scanWriterArgs(
        stripWriterRedirectWords(argv.args),
        valueShorts: inplaceCompressValueShorts,
        valueLongs: inplaceCompressValueLongs,
        bareShorts: inplaceCompressBareShorts,
        bareLongs: inplaceCompressBareLongs
    )
    var dests: [String] = []
    var recursive = false
    if scan.failed == false, scan.sawHelp == false,
        scan.bareShortHits.isDisjoint(with: inplaceCompressNoWriteShorts),
        scan.bareLongHits.isDisjoint(with: inplaceCompressNoWriteLongs)
    {
        dests += scan.operands
        dests += scan.candidates
        recursive = scan.bareShortHits.contains("r")
            || scan.bareLongHits.contains("recursive")
    }
    dests += writerRedirectDests(argv)
    guard dests.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .overwrite,
        paths: dests,
        recursive: recursive,
        force: false,
        mode: nil
    )
}

func parseInplaceCompress(_ args: [String]) -> ParsedFilesystemCommand? {
    parseInplaceCompress(Argv(program: "gzip", args: args))
}

private let zipValueShorts: Set<Character> = ["b", "n", "P", "s", "O"]

private let zipValueLongs: Set<String> = [
    "temp-dir", "suffixes", "password", "split-size", "output-file", "out",
    "compression-method", "encrypt",
]

private let zipBareShorts: Set<Character> = [
    "r", "j", "m", "q", "v", "f", "u", "o", "d", "D", "X", "y", "R", "S", "g",
    "A", "c", "z", "e", "T", "h", "V", "x", "i", "l", "L", "k", "0", "1", "2",
    "3", "4", "5", "6", "7", "8", "9",
]

private let zipBareLongs: Set<String> = [
    "recurse-patterns", "grow", "adjust-sfx", "junk-paths", "move", "quiet",
    "verbose", "freshen", "update", "latest-time", "delete",
    "no-dir-entries", "strip-extra", "symlinks", "license", "help",
    "version", "test", "archive-comment",
]

/// `zip archive files...` writes the archive (first operand; `-` means
/// stdout and is skipped). `-O`/`--output-file` redirects the new archive
/// elsewhere and `-b` names a temp dir: both are claimed. `-m` (move) also
/// deletes the sources, so the sources join the claim. `-x`/`-i` patterns
/// are operands but never the first, so they stay unclaimed.
func parseZip(_ argv: Argv) -> ParsedFilesystemCommand? {
    let scan = scanWriterArgs(
        stripWriterRedirectWords(argv.args),
        valueShorts: zipValueShorts,
        valueLongs: zipValueLongs,
        bareShorts: zipBareShorts,
        bareLongs: zipBareLongs
    )
    var dests: [String] = []
    if scan.failed == false, scan.sawHelp == false,
        let archive = scan.operands.first, archive != "-"
    {
        dests.append(archive)
        dests += scan.flagValues["O"] ?? []
        dests += scan.flagValues["output-file"] ?? []
        dests += scan.flagValues["out"] ?? []
        dests += scan.flagValues["b"] ?? []
        if scan.bareShortHits.contains("m") || scan.bareLongHits.contains("move") {
            dests += scan.operands.dropFirst()
        }
        dests += scan.candidates
    }
    dests += writerRedirectDests(argv)
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseZip(_ args: [String]) -> ParsedFilesystemCommand? {
    parseZip(Argv(program: "zip", args: args))
}

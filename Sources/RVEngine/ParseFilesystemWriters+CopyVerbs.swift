import RVDomain

// Part of the filesystem-writer parsers. Soundness rules shared by every
// writer parser live in the `ParseFilesystemWriters.swift` file header.

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
    // `-t` reads as a plain value short, and the blocking value shorts
    // share its left-to-right walk, so a `t` after one is that short's
    // attached value (`-StDIR` reads suffix `tDIR`), never a flag.
    // Conflicted shorts (BSD-bare/GNU-value) stay plain letters: they never
    // block `-t`, but one before it flags the override ambiguous.
    let spec = FlagValueSpec(valueShorts: valueShorts.union(["t"]))
    var overrides: [String] = []
    var reduced: [String] = []
    var overrideAmbiguous = false
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        switch FlagToken.classify(word) {
        case .terminator:
            reduced += args[index...]
            return (overrides, reduced, overrideAmbiguous)
        case .long(let name, let attached):
            if name == "target-directory", attached == nil {
                if index + 1 < args.endIndex {
                    args.formIndex(after: &index)
                    overrides.append(args[index])
                } else {
                    reduced.append(word)
                }
            } else if name == "target-directory", let attached {
                overrides.append(attached)
            } else {
                reduced.append(word)
            }
            args.formIndex(after: &index)
        case .shorts(let letters, _):
            if let split = spec.splitShortValue(letters),
                split.kept.last == "t"
            {
                foldTargetSplit(
                    kept: split.kept,
                    attached: split.attached,
                    args: args,
                    index: &index,
                    conflictedShorts: conflictedShorts,
                    overrides: &overrides,
                    reduced: &reduced,
                    overrideAmbiguous: &overrideAmbiguous
                )
            } else {
                reduced.append(word)
            }
            args.formIndex(after: &index)
        case .shortEquals(let name, let value):
            // Post-`=` text is the `=`-value, never cluster letters: a `t`
            // after `=` is not `-t` (`cp -S=t W a b` reads GNU suffix `=t`,
            // exact; the legacy scan also ate `W` as an override there).
            if let taken = spec.shortEqualsValue(name: name, value: value),
                case .shorts(let kept, let attached?) = taken,
                kept.last == "t"
            {
                foldTargetSplit(
                    kept: kept,
                    attached: attached,
                    args: args,
                    index: &index,
                    conflictedShorts: conflictedShorts,
                    overrides: &overrides,
                    reduced: &reduced,
                    overrideAmbiguous: &overrideAmbiguous
                )
            } else {
                reduced.append(word)
            }
            args.formIndex(after: &index)
        case .positional, .loneDash, .dangling:
            reduced.append(word)
            args.formIndex(after: &index)
        }
    }
    return (overrides, reduced, overrideAmbiguous)
}

/// Folds a `-t` cluster split: letters before `t` return to the reduced argv
/// (`-vtDIR` leaves `-v`); a conflicted letter among them flags the override
/// ambiguous; the attached rest (or the next word verbatim) is the override.
/// A dangling `-t` stays for the main scan to fail.
private func foldTargetSplit(
    kept: [Character],
    attached: String,
    args: [String],
    index: inout Array<String>.Index,
    conflictedShorts: Set<Character>,
    overrides: inout [String],
    reduced: inout [String],
    overrideAmbiguous: inout Bool
) {
    let before = kept.dropLast()
    if before.contains(where: conflictedShorts.contains) {
        overrideAmbiguous = true
    }
    if before.isEmpty == false {
        reduced.append("-" + String(before))
    }
    if attached.isEmpty == false {
        overrides.append(attached)
    } else if index + 1 < args.endIndex {
        args.formIndex(after: &index)
        overrides.append(args[index])
    } else {
        reduced.append("-t")
    }
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

// MARK: - cp / tee / install / ln

/// `cp` destination: the `-t` overrides, else the last operand. Every other
/// flag keeps the destination where getopt leaves it: `-T` only changes
/// file-vs-directory treatment, `-r`/`-n`/`-u` narrow what lands under it,
/// and `--backup`/`-b`/`-S` add same-directory sidecars. `-S` is conflicted
/// (GNU suffix value, BSD bare): attached rest reads as the suffix, a
/// separate `-S` stays bare, and each platform's destination stays sound.
func parseCp(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (targetDirs, reduced, overrideAmbiguous) = extractTargetDirectory(
        argv.args,
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
        argv.args,
        valueShorts: [],
        valueLongs: [],
        bareShorts: ["a", "i", "p"],
        bareLongs: ["append", "ignore-interrupts", "output-error"]
    )
    var dests: [String] = []
    if scan.failed == false, scan.sawHelp == false {
        // `tee /dev/null` copies stdin to stdout only: the exact discard
        // sink is no write target, as for a `>/dev/null` redirect.
        dests += (scan.operands + scan.candidates).filter { isDiscardSink($0) == false }
    }
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
    let (targetDirs, reduced, overrideAmbiguous) = extractTargetDirectory(
        argv.args,
        valueShorts: installValueShorts,
        conflictedShorts: ["S", "T"]
    )
    let dValues = extractInstallDValues(argv.args, valueShorts: installValueShorts)
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
/// operand links into the working directory. Parses as `.create`. A hard
/// link (no `-s`) also lists its sources: the new name writes through to
/// the same inode, so linking `~/.claude/settings.json` or a secret is a
/// write to it.
func parseLn(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (targetDirs, reduced, overrideAmbiguous) = extractTargetDirectory(
        argv.args,
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
        let symbolic = scan.bareShortHits.contains("s") || scan.bareLongHits.contains("symbolic")
        if symbolic == false {
            dests += hasOverride || scan.operands.count == 1 ? scan.operands : Array(scan.operands.dropLast())
        }
    }
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
        argv.args,
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

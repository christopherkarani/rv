import RVDomain

// Soundness rules shared by every writer parser live in the
// `ParseFilesystemWriters.swift` file header.

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
            return nil
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
            // which the fold's redirect union already collects.
            if ddStdioTargets.contains(target) == false {
                dests.append(target)
            }
        }
    }
    return writerParsed(operation: .overwrite, paths: dests)
}

private let ddStdioTargets: Set<String> = [
    "-", "/dev/stdout", "/dev/stderr", "/dev/stdin",
]

func parseDd(_ args: [String]) -> ParsedFilesystemCommand? {
    parseDd(Argv(program: "dd", args: args))
}

// MARK: - P10e9: iconv / split / sed / sqlite3

/// `iconv` writes `-o file` (`--output`) or stdout. Operands are inputs
/// (reads, never claimed).
func parseIconv(_ argv: Argv) -> ParsedFilesystemCommand? {
    let dests = extractOutputValues(
        argv.args,
        shorts: ["o"],
        longs: ["output"],
        skipShorts: ["f", "t"],
        skipLongs: ["from-code", "to-code"]
    )
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseIconv(_ args: [String]) -> ParsedFilesystemCommand? {
    parseIconv(Argv(program: "iconv", args: args))
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
        argv.args,
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
/// Script `w` targets are claimed too (`sedScriptEffects`). Residual: the GNU
/// `e` command executes; the unwrap peel limits it (`.sed`), not this parse.
func parseSed(_ argv: Argv) -> ParsedFilesystemCommand? {
    let scan = scanWriterArgs(
        argv.args,
        valueShorts: sedValueShorts,
        valueLongs: sedValueLongs,
        bareShorts: sedBareShorts,
        bareLongs: sedBareLongs,
        conflictedShorts: ["i", "I"]
    )
    var dests: [String] = []
    // The main scan drops bare `=`-longs, so `--in-place=.bak` also needs
    // the marker pre-scan (exact or unique-prefix, either `=` form).
    let inPlaceLong = argv.args.contains { word in
        guard word.hasPrefix("--") else { return false }
        let rest = String(word.dropFirst(2))
        let name: String
        if let equals = rest.firstIndex(of: "=") {
            name = String(rest[..<equals])
        } else {
            name = rest
        }
        return resolveWriterLong(name, valueLongs: [], bareLongs: ["in-place"])
            == "in-place"
    }
    if scan.failed == false, scan.sawHelp == false,
        scan.bareShortHits.contains("i") || scan.flagValues["i"] != nil
            || scan.bareShortHits.contains("I") || scan.flagValues["I"] != nil
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
    if scan.failed == false, scan.sawHelp == false {
        dests += sedScriptWriteTargets(scan)
    }
    return writerParsed(operation: .overwrite, paths: dests)
}

/// Files the sed script itself writes (`w`/`W` commands, `s///w` flag),
/// with or without `-i`. Scripts come from `-e`/`--expression`, else the
/// first non-empty operand; a `-f` script file is unreadable and ignored.
private func sedScriptWriteTargets(_ scan: WriterScan) -> [String] {
    var scripts = (scan.flagValues["e"] ?? []) + (scan.flagValues["expression"] ?? [])
    let fromFile = scan.flagValues["f"] != nil || scan.flagValues["file"] != nil
    if scripts.isEmpty, fromFile == false, let first = scan.operands.first(where: { $0.isEmpty == false }) {
        scripts.append(first)
    }
    return scripts.flatMap { sedScriptEffects($0).writeTargets }
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
    let (stripped, readonly) = stripSqliteDashWords(argv.args)
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

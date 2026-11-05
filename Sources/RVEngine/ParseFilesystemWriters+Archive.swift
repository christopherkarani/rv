import RVDomain

// Soundness rules shared by every writer parser live in the
// `ParseFilesystemWriters.swift` file header.

// MARK: - P10e9: unzip / ditto / gzip / zip

/// `unzip` extracts under the cwd or `-d dir`. Like `tar -x`, a default
/// extraction claims `"."` so `cd`-tracked outside cwds fail closed (M-05);
/// `.` resolves against the tracked cwd, so inside extraction stays quiet.
/// List/test/pipe modes never touch the disk and claim nothing. Residual:
/// archive-slip (`../../`) depends on member names, unknowable statically.
func parseUnzip(_ argv: Argv) -> ParsedFilesystemCommand? {
    if unzipListsOnly(argv.args) || unzipArchiveOperands(argv.args).isEmpty {
        return nil
    }
    var dests = extractOutputValues(argv.args, shorts: ["d"], longs: [])
    if dests.isEmpty {
        dests.append(".")
    }
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
        argv.args,
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
/// are the fold's claim). `-r` marks the claim recursive.
func parseInplaceCompress(_ argv: Argv) -> ParsedFilesystemCommand? {
    let scan = scanWriterArgs(
        argv.args,
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
        argv.args,
        valueShorts: zipValueShorts,
        valueLongs: zipValueLongs,
        bareShorts: zipBareShorts,
        bareLongs: zipBareLongs
    )
    var dests: [String] = []
    // Pure `-T`/`--test` with no file operands reads the archive;
    // there is nothing to update, so no archive claim (mirrors the
    // gzip `-t` no-write gate, but conditional: `zip -T archive files`
    // updates before testing and still claims). -m stays conservative.
    let testOnly = (scan.bareShortHits.contains("T") || scan.bareLongHits.contains("test"))
        && scan.operands.count == 1
        && scan.bareShortHits.contains("m") == false
        && scan.bareLongHits.contains("move") == false
    if scan.failed == false, scan.sawHelp == false,
        let archive = scan.operands.first, archive != "-"
    {
        if testOnly == false {
            dests.append(archive)
        }
        dests += scan.flagValues["O"] ?? []
        dests += scan.flagValues["output-file"] ?? []
        dests += scan.flagValues["out"] ?? []
        dests += scan.flagValues["b"] ?? []
        if scan.bareShortHits.contains("m") || scan.bareLongHits.contains("move") {
            dests += scan.operands.dropFirst()
        }
        dests += scan.candidates
    }
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseZip(_ args: [String]) -> ParsedFilesystemCommand? {
    parseZip(Argv(program: "zip", args: args))
}

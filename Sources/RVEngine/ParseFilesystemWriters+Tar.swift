import RVDomain

// Part of the filesystem-writer parsers. Soundness rules shared by every
// writer parser live in the `ParseFilesystemWriters.swift` file header.

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
    // Nil when the tool errored or printed help: the dispatcher's fold
    // still claims any shell-side redirect target.
    guard let scan = tarScan(argv.args) else {
        return nil
    }
    return tarDecide(scan)
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

private func tarDecide(_ scan: TarScan) -> ParsedFilesystemCommand? {
    if scan.unboundedExec {
        return writerParsed(
            operation: .overwrite,
            paths: [unboundedWriteSentinel]
        )
    }
    guard let mode = scan.mode else {
        return nil
    }
    switch mode {
    case "t", "d":
        // List/compare only read; a stdout redirect is the fold's claim.
        return nil
    case "c", "r", "u", "A", "D":
        var dests = scan.snapshotFiles
        if let archive = scan.archive {
            dests.append(archive)
        }
        return writerParsed(operation: .overwrite, paths: dests)
    case "x":
        if scan.absoluteNames {
            return writerParsed(
                operation: .overwrite,
                paths: [unboundedWriteSentinel]
            )
        }
        var dirs = scan.snapshotFiles
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

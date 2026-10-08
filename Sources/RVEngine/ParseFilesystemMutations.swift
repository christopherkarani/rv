import RVDomain

func parseRm(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = ShellPipeline.splitFlagTerminator(argv, values: rmFlagValues)
    var recursive = false
    var force = false
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, nil)
            where name == "recursive" || name == "dir" || name == "directory":
            recursive = true
        case .long(let name, nil) where name == "force":
            force = true
        case .long(let name, _) where name == "interactive":
            continue
        case .long(let name, nil) where rmSkipLong.contains("--" + name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(rmShorts.contains):
            if letters.contains("r") || letters.contains("R") || letters.contains("d") {
                recursive = true
            }
            if letters.contains("f") {
                force = true
            }
        default:
            return nil
        }
    }
    paths += rest
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: recursive,
        force: force,
        mode: nil
    )
}

func parseRm(_ args: [String]) -> ParsedFilesystemCommand? {
    parseRm(Argv(program: "rm", args: args))
}

private let rmSkipLong: Set<String> = [
    "--verbose", "--interactive", "--one-file-system",
    "--preserve-root", "--no-preserve-root",
]

// `-W`/`-x` are macOS-valid (whiteouts, stay-on-filesystem); `-P` is
// accepted for other BSD rms. Removed from macOS and absent from GNU,
// where the tool errors — over-accepting there only false-positives.
private let rmShorts: Set<Character> = ["r", "R", "d", "f", "v", "i", "I", "W", "x", "P"]

/// Bare-only spec: no consumption, but unique-prefix longs resolve
/// (`rm --rec` reads `--recursive`, exactly like getopt_long).
private let rmFlagValues = FlagValueSpec(knownLongs: [
    "recursive", "dir", "directory", "force", "verbose", "interactive",
    "one-file-system", "preserve-root", "no-preserve-root",
])

func parseUnlink(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = ShellPipeline.splitFlagTerminator(argv)
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        default:
            return nil
        }
    }
    paths += rest
    guard paths.count == 1 else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseUnlink(_ args: [String]) -> ParsedFilesystemCommand? {
    parseUnlink(Argv(program: "unlink", args: args))
}

func parseRmdir(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = ShellPipeline.splitFlagTerminator(argv, values: rmdirFlagValues)
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, nil) where rmdirSkip.contains("--" + name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(rmdirShorts.contains):
            continue
        default:
            return nil
        }
    }
    paths += rest
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseRmdir(_ args: [String]) -> ParsedFilesystemCommand? {
    parseRmdir(Argv(program: "rmdir", args: args))
}

private let rmdirSkip: Set<String> = [
    "--parents", "--verbose", "--ignore-fail-on-non-empty",
]

private let rmdirShorts: Set<Character> = ["p", "v"]

/// Bare-only spec: unique-prefix longs resolve, nothing consumes.
private let rmdirFlagValues = FlagValueSpec(knownLongs: [
    "parents", "verbose", "ignore-fail-on-non-empty",
])

func parseMv(_ argv: Argv) -> ParsedFilesystemCommand? {
    // Step 8B P10c: `-t DIR` / `--target-directory=DIR` moves the destination
    // out of last-operand position; without this the parse fails and the move
    // evaluates as no-action (ALLOW). The pre-scan removes the `-t` words so
    // the loop below is unchanged; the override appends as the destination.
    // `mv` keeps every operand, so an ambiguous `-t` needs no extra work:
    // both the override and the last operand already evaluate.
    let (targetDirs, reduced, _) = extractTargetDirectory(argv.args, valueShorts: ["S"])
    let (flags, rest) = ShellPipeline.splitFlagTerminator(
        Argv(program: argv.program, args: reduced),
        values: mvFlagValues
    )
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, nil) where mvSkipLong.contains("--" + name):
            continue
        case .long(let name, _) where mvValueSkipLong.contains(name):
            continue
        case .long(let name, let value?) where name == "target-directory":
            // Abbreviated `--targ DIR` (exact forms left in the pre-scan):
            // every `-t` value evaluates, so interleaved exact and
            // abbreviated overrides stay sound without last-wins tracking.
            paths.append(value)
        case .shorts(let letters, _) where letters.allSatisfy(mvShorts.contains):
            continue
        default:
            return nil
        }
    }
    paths += rest
    paths += targetDirs
    guard paths.count >= 2 else { return nil }
    return ParsedFilesystemCommand(
        operation: .move,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseMv(_ args: [String]) -> ParsedFilesystemCommand? {
    parseMv(Argv(program: "mv", args: args))
}

private let mvSkipLong: Set<String> = [
    "--force", "--interactive", "--no-clobber", "--verbose", "--update",
    "--strip-trailing-slashes", "--no-target-directory",
]

// Consumed-or-attached: `--suffix` (required value), `--backup` and
// `--context` (optional-`=`, bare here, attached accepted).
private let mvValueSkipLong: Set<String> = ["suffix", "backup", "context"]

// `-h` is macOS-valid (no-dereference); `-S` takes the backup suffix,
// `-T`/`-Z`/`-b` are GNU-only (the tool errors elsewhere, so accepting
// them only false-positives).
private let mvShorts: Set<Character> = ["f", "i", "n", "v", "u", "h", "S", "T", "Z", "b"]

private let mvFlagValues = FlagValueSpec(
    valueShorts: ["S"],
    valueLongs: ["suffix", "target-directory"],
    knownLongs: [
        "force", "interactive", "no-clobber", "verbose", "update",
        "strip-trailing-slashes", "no-target-directory", "backup", "context",
    ]
)

func parseTruncate(_ argv: Argv) -> ParsedFilesystemCommand? {
    let spec = FlagValueSpec(
        valueShorts: ["s", "r"],
        valueLongs: ["size", "reference"],
        knownLongs: ["no-create", "io-blocks", "verbose"]
    )
    let (flags, rest) = ShellPipeline.splitFlagTerminator(argv, values: spec)
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, _) where name == "size" || name == "reference":
            continue
        case .long(let name, nil) where truncateSkip.contains("--" + name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(truncateShorts.contains):
            continue
        default:
            return nil
        }
    }
    paths += rest
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .overwrite,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseTruncate(_ args: [String]) -> ParsedFilesystemCommand? {
    parseTruncate(Argv(program: "truncate", args: args))
}

private let truncateSkip: Set<String> = [
    "--no-create", "--io-blocks", "--verbose",
]

private let truncateShorts: Set<Character> = ["c", "o", "r", "s"]

func parseShred(_ argv: Argv) -> ParsedFilesystemCommand? {
    let spec = FlagValueSpec(
        valueShorts: ["n", "s"],
        valueLongs: ["iterations", "size", "random-source"],
        knownLongs: ["force", "remove", "zero", "verbose", "exact"]
    )
    let (flags, rest) = ShellPipeline.splitFlagTerminator(argv, values: spec)
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, nil) where shredSkipLong.contains("--" + name):
            continue
        case .long(let name, _) where shredAttachedLongs.contains(name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(shredShorts.contains):
            continue
        default:
            return nil
        }
    }
    paths += rest
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseShred(_ args: [String]) -> ParsedFilesystemCommand? {
    parseShred(Argv(program: "shred", args: args))
}

private let shredSkipLong: Set<String> = [
    "--force", "--remove", "--zero", "--verbose", "--exact",
]
private let shredAttachedLongs: Set<String> = [
    "remove", "iterations", "size", "random-source",
]
private let shredShorts: Set<Character> = ["f", "u", "z", "v", "x", "n", "s"]

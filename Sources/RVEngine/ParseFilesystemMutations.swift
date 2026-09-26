import RVDomain

/// Splits scanned flag events at the first `--` terminator.
///
/// Pre-terminator events keep their T3a grammar reading; post-terminator
/// words are recovered verbatim, matching the legacy loops where `--` made
/// every later word a positional.
func splitFlagTerminator(_ events: [FlagToken]) -> (flags: [FlagToken], rest: [String]) {
    guard let cut = events.firstIndex(of: .terminator) else {
        return (events, [])
    }
    return (
        Array(events[..<cut]),
        events[(cut + 1)...].flatMap(verbatimWords(of:))
    )
}

/// Recovers the raw argv words behind one scanned event: the exact inverse
/// of `FlagToken.classify` / `scanFlags` consumption for post-`--` recovery.
func verbatimWords(of event: FlagToken) -> [String] {
    switch event {
    case .positional(let word):
        return [word]
    case .terminator:
        return ["--"]
    case .loneDash:
        return ["-"]
    case .long(let name, let value):
        guard let value else { return ["--" + name] }
        return ["--" + name + "=" + value]
    case .shorts(let letters, let value):
        let word = "-" + String(letters)
        guard let value else { return [word] }
        return [word, value]
    case .shortEquals(let name, let value):
        return ["-" + name + "=" + value]
    case .dangling(let flag):
        return [flag]
    }
}

func parseRm(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv))
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

private let rmShorts: Set<Character> = ["r", "R", "d", "f", "v", "i", "I"]

func parseUnlink(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv))
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
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv))
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

func parseMv(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv))
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, nil) where mvSkipLong.contains("--" + name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(mvShorts.contains):
            continue
        default:
            return nil
        }
    }
    paths += rest
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
]

private let mvShorts: Set<Character> = ["f", "i", "n", "v", "u"]

func parseTruncate(_ argv: Argv) -> ParsedFilesystemCommand? {
    let spec = FlagValueSpec(valueShorts: ["s"], valueLongs: ["size"])
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv, values: spec))
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, _) where name == "size":
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
    let spec = FlagValueSpec(valueShorts: ["n", "s"], valueLongs: ["iterations", "size"])
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv, values: spec))
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, nil) where shredValueLong.contains("--" + name):
            continue
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
private let shredValueLong: Set<String> = [
    "--iterations", "--size",
]
private let shredAttachedLongs: Set<String> = [
    "remove", "iterations", "size",
]
private let shredShorts: Set<Character> = ["f", "u", "z", "v", "x", "n", "s"]

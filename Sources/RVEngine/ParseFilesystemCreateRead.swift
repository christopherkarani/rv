import RVDomain

func parseChmod(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = ShellPipeline.splitFlagTerminator(argv, values: chmodFlagValues)
    var recursive = false
    var mode: String?
    var modeExcused = false
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            if mode == nil, modeExcused == false {
                guard isChmodMode(word) else { return nil }
                mode = word
            } else {
                paths.append(word)
            }
        case .long(let name, nil) where name == "recursive":
            recursive = true
        case .long(let name, _) where name == "reference":
            // `--reference` replaces the mode operand (the tool errors when
            // both are given, which only false-positives here).
            modeExcused = true
        case .long(let name, _) where name == "from":
            continue
        case .long(let name, nil) where chmodSkipLong.contains("--" + name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(chmodShorts.contains):
            if letters.contains("R") {
                recursive = true
            }
            if letters.contains("a") {
                // `-a` replaces the mode operand with an ACE value.
                modeExcused = true
            }
        default:
            return nil
        }
    }
    for word in rest {
        if mode == nil, modeExcused == false {
            guard isChmodMode(word) else { return nil }
            mode = word
        } else {
            paths.append(word)
        }
    }
    guard paths.isEmpty == false, mode != nil || modeExcused else { return nil }
    return ParsedFilesystemCommand(
        operation: .chmod,
        paths: paths,
        recursive: recursive,
        force: false,
        mode: mode
    )
}

func parseChmod(_ args: [String]) -> ParsedFilesystemCommand? {
    parseChmod(Argv(program: "chmod", args: args))
}

private let chmodSkipLong: Set<String> = [
    "--silent", "--quiet", "--verbose", "--changes", "--no-dereference",
    "--dereference",
]

// `-H`/`-L`/`-P` are macOS-valid (symlink traversal with `-R`); `-a`
// takes an ACE value on macOS. `-c` is GNU-only (accepted: the tool
// errors elsewhere, so accepting it only false-positives).
private let chmodShorts: Set<Character> = ["R", "f", "v", "c", "h", "H", "L", "P", "a"]

private let chmodFlagValues = FlagValueSpec(
    valueShorts: ["a"],
    valueLongs: ["reference", "from"],
    knownLongs: [
        "recursive", "silent", "quiet", "verbose", "changes",
        "no-dereference", "dereference",
    ]
)

func isChmodMode(_ token: String) -> Bool {
    if token.allSatisfy({ $0 >= "0" && $0 <= "7" }), (3...4).contains(token.count) {
        return true
    }
    return token.contains(where: { $0 == "+" || $0 == "-" || $0 == "=" })
}

func parseTouch(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = ShellPipeline.splitFlagTerminator(argv, values: touchFlagValues)
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, _) where name == "date" || name == "time" || name == "reference":
            continue
        case .long(let name, nil) where touchSkipLong.contains("--" + name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(touchShorts.contains):
            continue
        default:
            return nil
        }
    }
    paths += rest
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .create,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseTouch(_ args: [String]) -> ParsedFilesystemCommand? {
    parseTouch(Argv(program: "touch", args: args))
}

// `-r` (reference file) and `-A` (adjustment) take values on macOS;
// `-d` is GNU-only (accepted: the tool errors elsewhere, so accepting
// it only false-positives).
private let touchFlagValues = FlagValueSpec(
    valueShorts: ["t", "d", "r", "A"],
    valueLongs: ["date", "time", "reference"],
    knownLongs: ["no-create", "no-dereference"]
)

private let touchSkipLong: Set<String> = [
    "--no-create", "--no-dereference", "--help", "--version",
]

private let touchShorts: Set<Character> = ["a", "c", "f", "h", "m", "t", "d", "r", "A"]

func parseMkdir(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = ShellPipeline.splitFlagTerminator(argv, values: mkdirFlagValues)
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, _) where name == "mode" || name == "context":
            continue
        case .long(let name, nil) where mkdirSkipLong.contains("--" + name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(mkdirShorts.contains):
            continue
        default:
            return nil
        }
    }
    paths += rest
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .create,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseMkdir(_ args: [String]) -> ParsedFilesystemCommand? {
    parseMkdir(Argv(program: "mkdir", args: args))
}

private let mkdirFlagValues = FlagValueSpec(
    valueShorts: ["m"],
    valueLongs: ["mode"],
    knownLongs: ["parents", "verbose", "context"]
)

private let mkdirSkipLong: Set<String> = [
    "--parents", "--verbose", "--help", "--version", "--context",
]

// `-Z`/`--context` are GNU-only (accepted: the tool errors on macOS,
// so accepting them only false-positives).
private let mkdirShorts: Set<Character> = ["p", "v", "m", "Z"]

func parseCat(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = ShellPipeline.splitFlagTerminator(argv)
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, nil) where catSkipLong.contains("--" + name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(catShorts.contains):
            continue
        default:
            return nil
        }
    }
    paths += rest
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .read,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseCat(_ args: [String]) -> ParsedFilesystemCommand? {
    parseCat(Argv(program: "cat", args: args))
}

private let catSkipLong: Set<String> = [
    "--show-all", "--number-nonblank", "--show-ends", "--number",
    "--squeeze-blank", "--show-tabs", "--show-nonprinting", "--help", "--version",
]

private let catShorts: Set<Character> = ["A", "b", "E", "e", "n", "s", "T", "t", "u", "v"]

func parseRedirectOnly(_ argv: Argv) -> ParsedFilesystemCommand? {
    guard let targets = redirectTargets(argv.fullCommand), targets.isEmpty == false else {
        return nil
    }
    return ParsedFilesystemCommand(
        operation: .overwrite,
        paths: targets,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseRedirectOnly(_ tokens: [String]) -> ParsedFilesystemCommand? {
    guard let first = tokens.first else { return nil }
    return parseRedirectOnly(Argv(program: first, args: Array(tokens.dropFirst())))
}

private func redirectTargets(_ tokens: [String]) -> [String]? {
    var targets: [String] = []
    var skipNext = false
    for index in tokens.indices {
        if skipNext {
            skipNext = false
            continue
        }
        let token = tokens[index]
        if isFdDup(token) {
            continue
        }
        if isRedirectOperator(token) {
            guard index + 1 < tokens.count else { return nil }
            skipNext = true
            let dest = tokens[index + 1]
            if dest.hasPrefix("&") {
                continue
            }
            targets.append(dest)
            continue
        }
        if let attached = attachedRedirectTarget(token) {
            targets.append(attached)
        }
    }
    return targets
}

func isFdDup(_ token: String) -> Bool {
    token == "2>&1" || token == "1>&2" || token == ">&1" || token == ">&2"
}

func isRedirectOperator(_ token: String) -> Bool {
    if token == "&>" || token == "&>>" || token == ">&" || token == "<>" {
        return true
    }
    // Optional fd digits (`2>`, `10>>`) then the operator. `<&` is excluded:
    // input-dups never name a destination.
    var rest = token[...]
    while let first = rest.first, first.isASCII, first.isNumber {
        rest = rest.dropFirst()
    }
    return rest == ">" || rest == ">|" || rest == ">>" || rest == ">&" || rest == "<>"
}

private func attachedRedirectTarget(_ token: String) -> String? {
    if token.hasPrefix(">>"), token.count > 2 {
        return String(token.dropFirst(2))
    }
    if token.hasPrefix(">|"), token.count > 2 {
        return String(token.dropFirst(2))
    }
    // `&>>file` and `>&file` before `&>`: otherwise the rest misparses
    // (`&>>/t` as `>/t`, `>&/t` as a dup).
    if token.hasPrefix("&>>"), token.count > 3 {
        return String(token.dropFirst(3))
    }
    // `>&file` duplicates to a file; `>&2` / `>&-` are dup/close, not files.
    if token.hasPrefix(">&"), token.count > 2 {
        let rest = String(token.dropFirst(2))
        if rest == "-" || rest.allSatisfy({ $0.isNumber }) {
            return nil
        }
        return rest.hasPrefix("&") ? nil : rest
    }
    if token.hasPrefix("&>"), token.count > 2 {
        let rest = String(token.dropFirst(2))
        return rest.hasPrefix("&") ? nil : rest
    }
    // `<>file` opens read-write: the target is writable.
    if token.hasPrefix("<>"), token.count > 2 {
        return String(token.dropFirst(2))
    }
    if token.hasPrefix(">"), token.count > 1, token.hasPrefix(">&") == false {
        return String(token.dropFirst())
    }
    // `[n]>word` / `[n]>>word` / `[n]>|word` / `[n]>&word` / `[n]<>word`.
    if let fdRest = stripRedirectFdDigits(token) {
        if fdRest.hasPrefix(">>"), fdRest.count > 2 {
            let rest = String(fdRest.dropFirst(2))
            return rest.hasPrefix("&") ? nil : rest
        }
        if fdRest.hasPrefix(">|"), fdRest.count > 2 {
            return String(fdRest.dropFirst(2))
        }
        if fdRest.hasPrefix(">&"), fdRest.count > 2 {
            let rest = String(fdRest.dropFirst(2))
            if rest == "-" || rest.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return nil
            }
            return rest.hasPrefix("&") ? nil : rest
        }
        if fdRest.hasPrefix("<>"), fdRest.count > 2 {
            return String(fdRest.dropFirst(2))
        }
        if fdRest.hasPrefix(">"), fdRest.count > 1, fdRest.hasPrefix(">&") == false {
            return String(fdRest.dropFirst())
        }
    }
    return nil
}

/// The operator remainder after fd digits, or nil when the token is not
/// digit-led (`>>x`, `>&x` keep their own arms above).
private func stripRedirectFdDigits(_ token: String) -> Substring? {
    var rest = token[...]
    var stripped = false
    while let first = rest.first, first.isASCII, first.isNumber {
        rest = rest.dropFirst()
        stripped = true
    }
    return stripped ? rest : nil
}



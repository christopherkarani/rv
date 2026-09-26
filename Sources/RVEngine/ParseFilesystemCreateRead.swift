import RVDomain

func parseChmod(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv))
    var recursive = false
    var mode: String?
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            if mode == nil {
                guard isChmodMode(word) else { return nil }
                mode = word
            } else {
                paths.append(word)
            }
        case .long(let name, nil) where name == "recursive":
            recursive = true
        case .long(let name, nil) where chmodSkipLong.contains("--" + name):
            continue
        case .shorts(let letters, _) where letters.allSatisfy(chmodShorts.contains):
            if letters.contains("R") {
                recursive = true
            }
        default:
            return nil
        }
    }
    for word in rest {
        if mode == nil {
            guard isChmodMode(word) else { return nil }
            mode = word
        } else {
            paths.append(word)
        }
    }
    guard let mode, paths.isEmpty == false else { return nil }
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
]

private let chmodShorts: Set<Character> = ["R", "f", "v", "c", "h"]

func isChmodMode(_ token: String) -> Bool {
    if token.allSatisfy({ $0 >= "0" && $0 <= "7" }), (3...4).contains(token.count) {
        return true
    }
    return token.contains(where: { $0 == "+" || $0 == "-" || $0 == "=" })
}

func parseTouch(_ argv: Argv) -> ParsedFilesystemCommand? {
    let spec = FlagValueSpec(valueShorts: ["t", "d"], valueLongs: ["date", "time"])
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv, values: spec))
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, _) where name == "date" || name == "time":
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

private let touchSkipLong: Set<String> = [
    "--no-create", "--no-dereference", "--help", "--version",
]

private let touchShorts: Set<Character> = ["a", "c", "f", "h", "m", "t", "d"]

func parseMkdir(_ argv: Argv) -> ParsedFilesystemCommand? {
    let spec = FlagValueSpec(valueShorts: ["m"], valueLongs: ["mode"])
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv, values: spec))
    var paths: [String] = []
    for event in flags {
        switch event {
        case .positional(let word):
            paths.append(word)
        case .long(let name, _) where name == "mode":
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

private let mkdirSkipLong: Set<String> = [
    "--parents", "--verbose", "--help", "--version",
]

private let mkdirShorts: Set<Character> = ["p", "v", "m"]

func parseCat(_ argv: Argv) -> ParsedFilesystemCommand? {
    let (flags, rest) = splitFlagTerminator(ShellPipeline.scanFlags(argv))
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
            if isDynamicToken(dest) { return nil }
            targets.append(dest)
            continue
        }
        if let attached = attachedRedirectTarget(token) {
            if isDynamicToken(attached) { return nil }
            targets.append(attached)
        }
    }
    return targets
}

func isFdDup(_ token: String) -> Bool {
    token == "2>&1" || token == "1>&2" || token == ">&1" || token == ">&2"
}

func isRedirectOperator(_ token: String) -> Bool {
    token == ">" || token == ">|" || token == ">>" || token == "&>" || token == "1>"
        || token == "2>"
}

private func attachedRedirectTarget(_ token: String) -> String? {
    if token.hasPrefix(">>"), token.count > 2 {
        return String(token.dropFirst(2))
    }
    if token.hasPrefix(">|"), token.count > 2 {
        return String(token.dropFirst(2))
    }
    if token.hasPrefix("&>"), token.count > 2 {
        let rest = String(token.dropFirst(2))
        return rest.hasPrefix("&") ? nil : rest
    }
    if token.hasPrefix("1>"), token.count > 2 {
        let rest = String(token.dropFirst(2))
        return rest.hasPrefix("&") ? nil : rest
    }
    if token.hasPrefix("2>"), token.count > 2 {
        let rest = String(token.dropFirst(2))
        return rest.hasPrefix("&") ? nil : rest
    }
    if token.hasPrefix(">"), token.count > 1, token.hasPrefix(">&") == false {
        return String(token.dropFirst())
    }
    return nil
}

private func isDynamicToken(_ token: String) -> Bool {
    // Home aliases contain `$` but are expanded lexically, not dynamically.
    // Exempt them so `echo hi > $HOME/.ssh/config` is not treated as unknown.
    if isHomeAliasPath(token) { return false }
    return token.contains("$") || token.contains("`")
}

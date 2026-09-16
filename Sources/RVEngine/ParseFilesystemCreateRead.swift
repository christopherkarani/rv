import RVDomain

func parseChmod(_ args: [String]) -> ParsedFilesystemCommand? {
    var recursive = false
    var mode: String?
    var paths: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            if mode == nil {
                guard isChmodMode(token) else { return nil }
                mode = token
            } else {
                paths.append(token)
            }
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if token == "--recursive" {
            recursive = true
            index += 1
            continue
        }
        if chmodSkipLong.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "R":
                    recursive = true
                case "f", "v", "c", "h":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        if mode == nil {
            guard isChmodMode(token) else { return nil }
            mode = token
        } else {
            paths.append(token)
        }
        index += 1
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

private let chmodSkipLong: Set<String> = [
    "--silent", "--quiet", "--verbose", "--changes", "--no-dereference",
]

func isChmodMode(_ token: String) -> Bool {
    if token.allSatisfy({ $0 >= "0" && $0 <= "7" }), (3...4).contains(token.count) {
        return true
    }
    return token.contains(where: { $0 == "+" || $0 == "-" || $0 == "=" })
}

func parseTouch(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var expectValue = false
    for token in args {
        if expectValue {
            expectValue = false
            continue
        }
        if seenDash {
            paths.append(token)
            continue
        }
        if token == "--" {
            seenDash = true
            continue
        }
        if token == "-t" || token == "-d" || token == "--date" || token == "--time" {
            expectValue = true
            continue
        }
        if token.hasPrefix("--date=") || token.hasPrefix("--time=") {
            continue
        }
        if touchSkipLong.contains(token) {
            continue
        }
        if let letters = clusteredShorts(token) {
            var valid = true
            for letter in letters {
                switch letter {
                case "a", "c", "f", "h", "m":
                    continue
                case "t", "d":
                    expectValue = true
                default:
                    valid = false
                }
            }
            if valid == false { return nil }
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
    }
    if expectValue { return nil }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .create,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let touchSkipLong: Set<String> = [
    "--no-create", "--no-dereference", "--help", "--version",
]

func parseMkdir(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var expectMode = false
    for token in args {
        if expectMode {
            expectMode = false
            continue
        }
        if seenDash {
            paths.append(token)
            continue
        }
        if token == "--" {
            seenDash = true
            continue
        }
        if token == "-m" || token == "--mode" {
            expectMode = true
            continue
        }
        if token.hasPrefix("--mode=") {
            continue
        }
        if mkdirSkipLong.contains(token) {
            continue
        }
        if let letters = clusteredShorts(token) {
            var valid = true
            for letter in letters {
                switch letter {
                case "p", "v":
                    continue
                case "m":
                    expectMode = true
                default:
                    valid = false
                }
            }
            if valid == false { return nil }
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
    }
    if expectMode { return nil }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .create,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let mkdirSkipLong: Set<String> = [
    "--parents", "--verbose", "--help", "--version",
]

func parseCat(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    for token in args {
        if seenDash {
            paths.append(token)
            continue
        }
        if token == "--" {
            seenDash = true
            continue
        }
        if catSkipLong.contains(token) {
            continue
        }
        if let letters = clusteredShorts(token) {
            var valid = true
            for letter in letters {
                switch letter {
                case "A", "b", "E", "e", "n", "s", "T", "t", "u", "v":
                    continue
                default:
                    valid = false
                }
            }
            if valid == false { return nil }
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
    }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .read,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let catSkipLong: Set<String> = [
    "--show-all", "--number-nonblank", "--show-ends", "--number",
    "--squeeze-blank", "--show-tabs", "--show-nonprinting", "--help", "--version",
]

func parseRedirectOnly(_ tokens: [String]) -> ParsedFilesystemCommand? {
    guard let targets = redirectTargets(tokens), targets.isEmpty == false else {
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

private func redirectTargets(_ tokens: [String]) -> [String]? {
    var targets: [String] = []
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        if isFdDup(token) {
            index += 1
            continue
        }
        if isRedirectOperator(token) {
            guard index + 1 < tokens.count else { return nil }
            let dest = tokens[index + 1]
            if dest.hasPrefix("&") {
                index += 2
                continue
            }
            if isDynamicToken(dest) { return nil }
            targets.append(dest)
            index += 2
            continue
        }
        if let attached = attachedRedirectTarget(token) {
            if isDynamicToken(attached) { return nil }
            targets.append(attached)
        }
        index += 1
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

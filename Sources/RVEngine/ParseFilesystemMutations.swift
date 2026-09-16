import RVDomain

func parseRm(_ args: [String]) -> ParsedFilesystemCommand? {
    var recursive = false
    var force = false
    var paths: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if token == "--recursive" || token == "--dir" || token == "--directory" {
            recursive = true
            index += 1
            continue
        }
        if token == "--force" {
            force = true
            index += 1
            continue
        }
        if rmSkipLong.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "r", "R", "d":
                    recursive = true
                case "f":
                    force = true
                case "v", "i", "I":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: recursive,
        force: force,
        mode: nil
    )
}

private let rmSkipLong: Set<String> = [
    "--verbose", "--interactive", "--one-file-system",
    "--preserve-root", "--no-preserve-root",
]

func parseUnlink(_ args: [String]) -> ParsedFilesystemCommand? {
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
        if token == "--help" || token == "--version" {
            return nil
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
    }
    guard paths.count == 1 else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

func parseRmdir(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if rmdirSkip.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "p", "v":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let rmdirSkip: Set<String> = [
    "--parents", "--verbose", "--ignore-fail-on-non-empty",
]

func parseMv(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if mvSkipLong.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "f", "i", "n", "v", "u":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    guard paths.count >= 2 else { return nil }
    return ParsedFilesystemCommand(
        operation: .move,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let mvSkipLong: Set<String> = [
    "--force", "--interactive", "--no-clobber", "--verbose", "--update",
]

func parseTruncate(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var expectSize = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if expectSize {
            expectSize = false
            index += 1
            continue
        }
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if token == "-s" || token == "--size" {
            expectSize = true
            index += 1
            continue
        }
        if token.hasPrefix("--size=") {
            index += 1
            continue
        }
        if truncateSkip.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "c", "o", "r":
                    continue
                case "s":
                    expectSize = true
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    if expectSize { return nil }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .overwrite,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let truncateSkip: Set<String> = [
    "--no-create", "--io-blocks", "--verbose",
]

func parseShred(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var expectValue = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if expectValue {
            expectValue = false
            index += 1
            continue
        }
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if shredValueLong.contains(token) {
            expectValue = true
            index += 1
            continue
        }
        if shredSkipLong.contains(token) || token.hasPrefix("--remove=")
            || token.hasPrefix("--iterations=") || token.hasPrefix("--size=")
        {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "f", "u", "z", "v", "x":
                    continue
                case "n", "s":
                    expectValue = true
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    if expectValue { return nil }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let shredSkipLong: Set<String> = [
    "--force", "--remove", "--zero", "--verbose", "--exact",
]
private let shredValueLong: Set<String> = [
    "--iterations", "--size",
]


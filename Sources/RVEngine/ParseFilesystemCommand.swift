import RVDomain

struct ParsedFilesystemCommand {
    var operation: FilesystemOperation
    var paths: [String]
    var recursive: Bool
    var force: Bool
    var mode: String?
}

enum FilesystemOperation {
    case delete
    case move
    case overwrite
    case chmod
    case create
    case read
}

func parseFilesystemCommand(_ argv: Argv) -> ParsedFilesystemCommand? {
    let head = basename(argv.program).lowercased()
    switch head {
    case "rm":
        return parseRm(argv)
    case "unlink":
        return parseUnlink(argv)
    case "rmdir":
        return parseRmdir(argv)
    case "mv":
        return parseMv(argv)
    case "chmod":
        return parseChmod(argv)
    case "truncate":
        return parseTruncate(argv)
    case "shred":
        return parseShred(argv)
    case "touch":
        return parseTouch(argv)
    case "mkdir":
        return parseMkdir(argv)
    case "cat":
        if let redirect = parseRedirectOnly(argv), redirect.paths.isEmpty == false {
            return redirect
        }
        return parseCat(argv)
    default:
        return parseRedirectOnly(argv)
    }
}

func parseFilesystemCommand(_ tokens: [String]) -> ParsedFilesystemCommand? {
    guard let first = tokens.first else { return nil }
    return parseFilesystemCommand(Argv(program: first, args: Array(tokens.dropFirst())))
}

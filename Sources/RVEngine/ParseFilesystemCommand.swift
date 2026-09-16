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

func parseFilesystemCommand(_ tokens: [String]) -> ParsedFilesystemCommand? {
    guard let first = tokens.first else { return nil }
    let head = basename(first).lowercased()
    switch head {
    case "rm":
        return parseRm(Array(tokens.dropFirst()))
    case "unlink":
        return parseUnlink(Array(tokens.dropFirst()))
    case "rmdir":
        return parseRmdir(Array(tokens.dropFirst()))
    case "mv":
        return parseMv(Array(tokens.dropFirst()))
    case "chmod":
        return parseChmod(Array(tokens.dropFirst()))
    case "truncate":
        return parseTruncate(Array(tokens.dropFirst()))
    case "shred":
        return parseShred(Array(tokens.dropFirst()))
    case "touch":
        return parseTouch(Array(tokens.dropFirst()))
    case "mkdir":
        return parseMkdir(Array(tokens.dropFirst()))
    case "cat":
        if let redirect = parseRedirectOnly(tokens), redirect.paths.isEmpty == false {
            return redirect
        }
        return parseCat(Array(tokens.dropFirst()))
    default:
        return parseRedirectOnly(tokens)
    }
}


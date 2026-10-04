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
    // Redirects are shell-side: when the verb parse fails (unknown flags,
    // help, dangling values) the shell still truncated the redirect target,
    // so every verb falls back to the redirect parse. `cat` keeps its own
    // redirect-first order; the new writer verbs union internally.
    case "rm":
        return parseRm(argv) ?? parseRedirectOnly(argv)
    case "unlink":
        return parseUnlink(argv) ?? parseRedirectOnly(argv)
    case "rmdir":
        return parseRmdir(argv) ?? parseRedirectOnly(argv)
    case "mv":
        return parseMv(argv) ?? parseRedirectOnly(argv)
    case "cp":
        return parseCp(argv)
    case "tee":
        return parseTee(argv)
    case "install":
        return parseInstall(argv)
    case "ln":
        return parseLn(argv)
    case "rsync":
        return parseRsync(argv)
    case "tar":
        return parseTar(argv)
    case "curl":
        return parseCurl(argv)
    case "dd":
        return parseDd(argv)
    case "wget":
        return parseWget(argv)
    case "iconv":
        return parseIconv(argv)
    case "unzip":
        return parseUnzip(argv)
    case "split":
        return parseSplit(argv)
    case "sed":
        return parseSed(argv)
    case "sqlite3":
        return parseSqlite3(argv)
    case "ditto":
        return parseDitto(argv)
    case "gzip", "gunzip", "bzip2", "bunzip2", "xz", "unxz", "compress",
        "uncompress":
        return parseInplaceCompress(argv)
    case "zip":
        return parseZip(argv)
    case "chmod":
        return parseChmod(argv) ?? parseRedirectOnly(argv)
    case "truncate":
        return parseTruncate(argv) ?? parseRedirectOnly(argv)
    case "shred":
        return parseShred(argv) ?? parseRedirectOnly(argv)
    case "touch":
        return parseTouch(argv) ?? parseRedirectOnly(argv)
    case "mkdir":
        return parseMkdir(argv) ?? parseRedirectOnly(argv)
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

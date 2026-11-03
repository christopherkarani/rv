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

/// The filesystem-command seam. Redirect stripping before the verb
/// scan and the redirect union after it happen exactly once here, in
/// `WriterRedirectFold`; verb parsers take the stripped argv and own
/// only their destination grammar. Redirects are shell-side: when the
/// verb parse fails (unknown flags, help, dangling values) the shell
/// still truncated the redirect target, so the fold falls back to the
/// redirect-only overwrite for every verb, known or not.
func parseFilesystemCommand(_ argv: Argv) -> ParsedFilesystemCommand? {
    let fold = WriterRedirectFold(argv)
    return fold.union(parseFilesystemVerb(fold.stripped))
}

private func parseFilesystemVerb(_ argv: Argv) -> ParsedFilesystemCommand? {
    let head = unescapeBackslashPairs(basename(argv.program)).lowercased()
    switch head {
    case "rm":
        return parseRm(argv)
    case "unlink":
        return parseUnlink(argv)
    case "rmdir":
        return parseRmdir(argv)
    case "mv":
        return parseMv(argv)
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
        return parseCat(argv)
    default:
        return nil
    }
}

func parseFilesystemCommand(_ tokens: [String]) -> ParsedFilesystemCommand? {
    guard let first = tokens.first else { return nil }
    return parseFilesystemCommand(Argv(program: first, args: Array(tokens.dropFirst())))
}

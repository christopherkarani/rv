import RVDomain

// Part of the filesystem-writer parsers. Soundness rules shared by every
// writer parser live in the `ParseFilesystemWriters.swift` file header.

// MARK: - curl

/// `curl` file destinations: `-o`/`--output`, `-O`/`--remote-name` /
/// `--remote-name-all` (into `--output-dir` or the working directory),
/// `-D`/`--dump-header`, `--trace`/`--trace-ascii`, `-c`/`--cookie-jar`,
/// `--hsts`, `--stderr`, `--etag-save`, `--alt-svc`, `--libcurl`,
/// `--dump-ca-embed`, `--ssl-keylogfile`, and `-K`/`--config` (a config
/// file can name any option, so it reads as unbounded). Longs resolve
/// unique prefixes (curl abbreviates); `-o=x` consumes its `=` rest like
/// getopt. Every other flag is skipped: curl's remaining surface reads,
/// prints, or tunes the transfer, and skipping is sound here because only
/// the collected values feed a destination — an unknown flag either errors
/// the tool (fail-closed noise) or runs with its destinations still
/// extracted. A `-` value means stdout.
func parseCurl(_ argv: Argv) -> ParsedFilesystemCommand? {
    var dests: [String] = []
    var outputDirs: [String] = []
    var remoteName = false
    var index = argv.args.startIndex
    while index < argv.args.endIndex {
        let word = argv.args[index]
        if word == "--" {
            break
        }
        if word.hasPrefix("--"), word.count > 2 {
            let rest = String(word.dropFirst(2))
            let rawName: String
            let attached: String?
            if let equals = rest.firstIndex(of: "=") {
                rawName = String(rest[..<equals])
                attached = String(rest[rest.index(after: equals)...])
            } else {
                rawName = rest
                attached = nil
            }
            switch resolveCurlLong(rawName) {
            case "output", "dump-header", "trace", "trace-ascii",
                "cookie-jar", "hsts", "stderr", "etag-save", "alt-svc",
                "libcurl", "dump-ca-embed", "ssl-keylogfile":
                if let value = attached ?? curlNextWord(argv.args, &index) {
                    dests.append(value)
                }
            case "output-dir":
                if let value = attached ?? curlNextWord(argv.args, &index) {
                    outputDirs.append(value)
                }
            case "remote-name", "remote-name-all":
                remoteName = true
            case "config":
                // A config file can name any curl option (including `-o`
                // anywhere), and its content is unbounded statically.
                if attached ?? curlNextWord(argv.args, &index) != nil {
                    dests.append(unboundedWriteSentinel)
                }
            case "help", "version", "manual":
                // Help prints and writes nothing; the fold claims any
                // shell-side redirect target.
                return nil
            default:
                break
            }
            argv.args.formIndex(after: &index)
            continue
        }
        if word.hasPrefix("-"), word.count > 1 {
            let letters = Array(word.dropFirst())
            var letterIndex = letters.startIndex
            while letterIndex < letters.endIndex {
                let letter = letters[letterIndex]
                switch letter {
                case "o", "D", "c":
                    let rest = String(letters[letters.index(after: letterIndex)...])
                    if rest.isEmpty == false {
                        dests.append(rest)
                    } else if let value = curlNextWord(argv.args, &index) {
                        dests.append(value)
                    }
                    letterIndex = letters.endIndex
                case "K":
                    // `-K`/`--config` content is unbounded (see above).
                    let rest = String(letters[letters.index(after: letterIndex)...])
                    if rest.isEmpty == false || curlNextWord(argv.args, &index) != nil {
                        dests.append(unboundedWriteSentinel)
                    }
                    letterIndex = letters.endIndex
                case "O":
                    remoteName = true
                    letters.formIndex(after: &letterIndex)
                default:
                    letters.formIndex(after: &letterIndex)
                }
            }
            argv.args.formIndex(after: &index)
            continue
        }
        argv.args.formIndex(after: &index)
    }
    if outputDirs.isEmpty == false {
        // --output-dir prepends to relative -o names (man) as well as
        // remote names; claiming the raw relative path would resolve
        // inside while curl writes outside. Claim the joined form too.
        // Superset over order and --next transfers: every dir seen
        // anywhere joins every relative curl dest, so no transfer can
        // under-claim. Shell-redirect dests (the fold's union) are
        // unaffected by curl's output-dir and never join.
        let curlDests = dests
        for dir in outputDirs {
            for dest in curlDests {
                if let joined = joinCurlOutputDir(dir, dest) {
                    dests.append(joined)
                }
            }
        }
    }
    if remoteName {
        if outputDirs.isEmpty {
            dests.append(".")
        } else {
            dests += outputDirs
        }
    }
    dests.removeAll { $0 == "-" }
    return writerParsed(operation: .overwrite, paths: dests)
}

/// Joins a curl `-o`-family dest onto one --output-dir. Absolute dests
/// win over the dir (man); stdout ("-") and empty dirs never join. The
/// unbounded sentinel ("/") is absolute by shape and passes through.
private func joinCurlOutputDir(_ dir: String, _ dest: String) -> String? {
    guard dir.isEmpty == false, dest != "-", dest.hasPrefix("/") == false else {
        return nil
    }
    if dir.hasSuffix("/") {
        return dir + dest
    }
    return dir + "/" + dest
}

/// Resolves a curl long against the write-flag universe (exact first, then
/// the unique prefix), matching curl's getopt_long abbreviation. Unknown
/// longs skip: curl's remaining flags read, print, or tune the transfer,
/// and none names a file curl writes. `help`/`version`/`manual` stay
/// exact-only: an abbreviated help still prints (nothing runs), so the
/// parsed destinations can only false-positive.
private func resolveCurlLong(_ name: String) -> String {
    if curlWriteLongs.contains(name) {
        return name
    }
    var match: String?
    for candidate in curlWriteLongs {
        guard candidate.hasPrefix(name) else { continue }
        guard match == nil else { return name }
        match = candidate
    }
    return match ?? name
}

private let curlWriteLongs: Set<String> = [
    "output", "output-dir", "remote-name", "remote-name-all",
    "dump-header", "trace", "trace-ascii", "cookie-jar", "hsts",
    "stderr", "etag-save", "alt-svc", "libcurl", "dump-ca-embed",
    "ssl-keylogfile", "config",
]

func parseCurl(_ args: [String]) -> ParsedFilesystemCommand? {
    parseCurl(Argv(program: "curl", args: args))
}

/// Next word, or nil at end of argv (the tool errors; the permissive curl
/// scan skips instead of failing).
private func curlNextWord(_ args: [String], _ index: inout Array<String>.Index) -> String? {
    guard index + 1 < args.endIndex else { return nil }
    args.formIndex(after: &index)
    return args[index]
}

/// `wget` writes `-O file` / `-P dir` (+ `--output-document`,
/// `--directory-prefix`) and the `-o` / `-a` log files. Default fetches land
/// under the cwd (inside, unclaimed). Residual: `-e` executes wgetrc
/// commands, so `-e logfile=/tmp/x` redirects output opaquely (same class as
/// every other embedded-language residual).
func parseWget(_ argv: Argv) -> ParsedFilesystemCommand? {
    let dests = extractOutputValues(
        argv.args,
        shorts: ["O", "P", "o", "a"],
        longs: ["output-document", "directory-prefix", "output-file", "append-output"],
        skipShorts: ["e"],
        skipLongs: ["execute"]
    )
    return writerParsed(operation: .overwrite, paths: dests)
}

func parseWget(_ args: [String]) -> ParsedFilesystemCommand? {
    parseWget(Argv(program: "wget", args: args))
}

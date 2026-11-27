import Foundation

/// Positive safe-command lane (laya-guard `safe_commands` parity).
///
/// A command enters only when the packs already allowed the whole string
/// AND every chain segment is a plain command: no shell metacharacters,
/// no program-running flags, no sensitive paths, and a full match
/// against the allowlist below. Build/test entries execute project code
/// by design (as do `git commit` hooks); `mkdir`/`touch` write the plain
/// paths named. The lane only waives the ML judge, never a pack deny,
/// and the package.json script check runs before it, so a poisoned
/// `npm test` never enters (an unresolved script graph never enters
/// either — see `JudgeRuntime.apply`). Installs, `git push`, and `npx`
/// are deliberately absent.
/// Split on top-level `&&`, `||`, `;`, `&`, `|`, and newlines outside
/// quotes (laya-guard chain handling: each segment is judged on its own).
/// Scans unicode scalars, not Characters: a grapheme cluster joins a
/// separator to its neighbour (`"\r\n"`, `"\u{600};"`), but the shell
/// reads the byte. A lone `\r` splits too, as the engine tokenizer does.
func shellChainSegments(_ raw: String) -> [String] {
    var segments: [String] = []
    var current = String.UnicodeScalarView()
    var inSingle = false
    var inDouble = false
    let scalars = Array(raw.unicodeScalars)
    var i = 0
    func cut() {
        segments.append(String(current))
        current = String.UnicodeScalarView()
    }
    while i < scalars.count {
        let ch = scalars[i]
        if ch == "'" && !inDouble { inSingle.toggle() }
        else if ch == "\"" && !inSingle { inDouble.toggle() }
        else if !inSingle && !inDouble {
            if ch == ";" || ch == "\n" || ch == "\r" { cut(); i += 1; continue }
            if ch == "&" || ch == "|" {
                // `&&`/`||` take two scalars; a single `|` is a pipe: the
                // receiving segment is a command of its own and must pass
                // on its own.
                let doubled = i + 1 < scalars.count && scalars[i + 1] == ch
                cut(); i += doubled ? 2 : 1; continue
            }
        }
        current.append(ch)
        i += 1
    }
    cut()
    return segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

public enum SafeCommandLane {
    public static func isSafe(_ raw: String) -> Bool {
        let segments = shellChainSegments(raw)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy(isSafeSingle)
    }

    static func isSafeSingle(_ raw: String) -> Bool {
        // Newlines are command separators: segmentation already split
        // unquoted ones, so any newline surviving in a segment is
        // quoted — not a plain command. Checked on the raw segment,
        // before whitespace normalization can erase it.
        // Scalars, not Characters, here and below: `">\u{301}"` is one
        // Character that is not `>`, yet the shell reads the `>` byte.
        if raw.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { return false }
        let text = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        guard !text.isEmpty else { return false }
        if text.unicodeScalars.contains(where: { metacharacters.contains($0) }) { return false }
        // The shell strips quotes, so flag/path scans run dequoted:
        // `go test "-exec" /tmp/evil` must scan as `-exec`.
        var scanned = ""
        scanned.unicodeScalars.append(contentsOf: text.unicodeScalars.filter { $0 != "'" && $0 != "\"" })
        if regexSearch(riskyFlagPattern, in: scanned) { return false }
        if regexSearch(sensitivePathPattern, in: scanned) { return false }
        guard patterns.contains(where: { regexSearch("^(?:" + $0 + ")$", in: text) }) else { return false }
        return programChecksPass(scanned)
    }

    /// Per-program flag rules the shared patterns cannot express. Runs
    /// on dequoted tokens of an already pattern-matched segment.
    static func programChecksPass(_ scanned: String) -> Bool {
        let tokens = scanned.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let head = tokens.first else { return false }
        if tokens.contains("-C") { return false }
        switch head {
        case "go":
            // `-o` writes an arbitrary output path.
            if tokens.contains(where: { $0 == "-o" || $0.hasPrefix("-o=") }) { return false }
        case "pytest":
            return pytestTokensPass(Array(tokens.dropFirst()))
        case "python", "python3":
            // Only the `-m pytest` form needs pytest rules; the
            // version forms are already pinned by the patterns.
            if tokens.count > 1, tokens[1] == "-m" {
                guard tokens.count > 2, tokens[2] == "pytest" else { return false }
                return pytestTokensPass(Array(tokens.dropFirst(3)))
            }
            return true
        default:
            break
        }
        return true
    }

    /// pytest loads plugins (`-p`, `-o`, `--pyargs`, config files) and
    /// collects code by path: only in-tree relative collection passes.
    static func pytestTokensPass(_ tokens: [String]) -> Bool {
        for token in tokens {
            if token == "-p" || token.hasPrefix("-p") && !token.hasPrefix("--") { return false }
            if token == "-o" || token == "-c" || token == "--pyargs" { return false }
            if token.hasPrefix("/") || token.hasPrefix("~") { return false }
            if token == ".." || token.hasPrefix("../") || token.contains("/../") { return false }
        }
        return true
    }

    private static let metacharacters: Set<Unicode.Scalar> = [";", "&", "|", "`", "$", "<", ">", "(", ")", "{", "}", "\\", "\n", "\r"]

    private static let riskyFlagPattern =
        #"(?:^|\s)--?(?:exec|toolexec|vettool|pre|hostname-bin|config|output|out-dir|target-dir|scratch-path|prefix|dir|cwd|workspace|workspaces|pyargs|rootdir|upload-pack|receive-pack|script-shell|node-options|userconfig|globalconfig)(?:[=\s]|$)"#

    private static let sensitivePathPattern =
        #"\.ssh|\.aws|\.gnupg|\.kube|\.netrc|\.npmrc|\.pypirc|\.env\b|\.envrc|\.git-credentials|id_rsa|id_ed25519|credentials|/etc/(shadow|sudoers)|_history\b|\.pem\b|\.key\b|\.docker\b|\.pgpass|hosts\.yml"#

    /// laya-guard `safe_commands` (POSIX subset) + SwiftPM equivalents.
    static let patterns: [String] = [
        #"ls( \S+)*"#,
        #"pwd"#,
        #"cd( \S+)?"#,
        #"(true|false|whoami|date|uptime|clear)"#,
        #"sleep [0-9.]+[smh]?"#,
        #"(uname|df|free)( -\w+)*"#,
        #"du( \S+)+"#,
        #"which( \S+)+"#,
        #"echo( \S+)*"#,
        #"(cat|head|tail|wc|grep|rg)( \S+)+"#,
        #"(mkdir|touch)( \S+)+"#,
        #"git (status|diff|log|show|add|commit|switch)( \S+)*"#,
        #"git branch( (-a|-r|-v|-vv|--list|--show-current|\w[\w./-]*))*"#,
        #"git stash( (list|show|push)( \S+)*)?"#,
        #"git checkout -b \S+"#,
        #"(npm|pnpm|yarn|bun) (test|build|lint|run (build|test|lint|typecheck|format|check))( \S+)*"#,
        #"(pytest|python3? -m pytest)( \S+)*"#,
        #"go (build|test|vet|fmt)( \S+)*"#,
        #"cargo (build|test|check|fmt|clippy)( \S+)*"#,
        #"swift (build|test)( \S+)*"#,
        #"make( (build|test|lint|check|all))?"#,
        #"docker (ps|images)( \S+)*"#,
        #"(node|npm|pnpm|yarn|bun|python3?|pip3?|go|cargo|rustc|git|docker|java|ruby|swift) (--version|-v|-V|version)"#,
    ] + rvReadOnlyPatterns

    /// B2: rv's own read-only verbs, so an agent can look at rv (status,
    /// log, why, doctor, help, box list) without the judge in the way. Each
    /// is spelled out with the only flags it takes: a write verb, or a
    /// read verb with any other flag, does not match. The lane only waives
    /// the judge: a command self-protection floors never reaches it, since
    /// the packs did not allow it.
    static let rvReadOnlyPatterns: [String] = [
        #"rv( (status|doctor))?( --(json|robot|plain))?"#,
        #"rv (log|blocks)( (--json|--robot|--plain|--all|--rule [a-z0-9][a-z0-9._:/-]*|--host [a-z]+|-n [0-9]+))*"#,
        #"rv why [0-9a-f-]{3,20}( --(json|robot|plain))?"#,
        #"rv explain( \S+)+"#,
        #"rv box list( --(json|robot|plain))?"#,
        #"rv (service|policy) status( --(json|robot|plain))?"#,
        #"rv( [a-z][a-z-]*){1,2} (--help|-h)"#,
        #"rv (--help|-h|--version|version|help( [a-z][a-z-]*){0,2})"#,
    ]

    private static func regexSearch(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

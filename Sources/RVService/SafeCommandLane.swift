import Foundation

/// Positive safe-command lane (laya-guard `safe_commands` parity).
///
/// A command enters only when the packs already allowed the whole string
/// AND it is a single plain command: no shell metacharacters, no
/// program-running or file-writing flags, no sensitive paths, and a
/// full match against the allowlist below. The package.json script
/// check runs before this lane, so a poisoned `npm test` never enters.
/// Installs, `git push`, and `npx` are deliberately absent.
/// Split on top-level `&&`, `||`, `;`, `&` outside quotes (laya-guard
/// chain handling: each segment is judged on its own).
func shellChainSegments(_ raw: String) -> [String] {
    var segments: [String] = []
    var current = ""
    var inSingle = false
    var inDouble = false
    var chars = Array(raw)
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        if ch == "'" && !inDouble { inSingle.toggle() }
        else if ch == "\"" && !inSingle { inDouble.toggle() }
        else if !inSingle && !inDouble {
            if ch == ";" { segments.append(current); current = ""; i += 1; continue }
            if ch == "&" || ch == "|" {
                if i + 1 < chars.count && chars[i + 1] == ch {
                    segments.append(current); current = ""; i += 2; continue
                }
                if ch == "&" { segments.append(current); current = ""; i += 1; continue }
            }
        }
        current.append(ch)
        i += 1
    }
    segments.append(current)
    return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

public enum SafeCommandLane {
    public static func isSafe(_ raw: String) -> Bool {
        let segments = shellChainSegments(raw)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy(isSafeSingle)
    }

    static func isSafeSingle(_ raw: String) -> Bool {
        let text = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
        guard !text.isEmpty else { return false }
        if metacharacters.contains(where: { text.contains($0) }) { return false }
        if regexSearch(riskyFlagPattern, in: text) { return false }
        if regexSearch(sensitivePathPattern, in: text) { return false }
        return patterns.contains { regexSearch("^(?:" + $0 + ")$", in: text) }
    }

    private static let metacharacters: [Character] = [";", "&", "|", "`", "$", "<", ">", "(", ")", "{", "}", "\\", "\n", "\r"]

    private static let riskyFlagPattern =
        #"(?:^|\s)--?(?:exec|toolexec|config|output|upload-pack|receive-pack|script-shell|node-options|userconfig|globalconfig)(?:[=\s]|$)"#

    private static let sensitivePathPattern =
        #"\.ssh|\.aws|\.gnupg|\.kube|\.netrc|\.npmrc|\.pypirc|\.env\b|\.git-credentials|id_rsa|id_ed25519|credentials|/etc/(shadow|sudoers)"#

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
    ]

    private static func regexSearch(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

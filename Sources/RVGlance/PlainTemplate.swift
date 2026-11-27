import Foundation
import RVIPC

/// The deterministic explainer: a table of common risky commands and file
/// actions, then the rule id as a hint, then a generic line by tool. It is
/// the fallback for every other explainer and the oracle in tests.
public struct PlainTemplate: PlainExplainer {
    public init() {}

    public func explain(_ request: PlainRequest) async -> PlainLine {
        Self.line(for: request)
    }

    public static func line(for request: PlainRequest) -> PlainLine {
        PlainLine(text: PlainText.clamp(sentence(for: request)), source: .template)
    }

    /// True when the table or the rule hint knows this action, so its line
    /// says more than "Would run …". `PlainFallback` asks a model only when
    /// it does not: the table is exact where it applies.
    public static func recognises(_ request: PlainRequest) -> Bool {
        switch request.tool {
        case .bash: known(request) != nil
        case .read, .edit, .write: true
        }
    }

    static func known(_ request: PlainRequest) -> String? {
        PlainCommand.explain(request.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? hint(request.rule)
    }

    static func sentence(for request: PlainRequest) -> String {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.tool {
        case .bash:
            return known(request) ?? (text.isEmpty ? "Would run a shell command" : "Would run \(text)")
        case .read:
            guard !text.isEmpty else { return hint(request.rule) ?? "Would read a file" }
            return PlainPath.isSecret(text)
                ? "Would read the secrets file \(PlainPath.short(text))" : "Would read \(PlainPath.short(text))"
        case .edit, .write:
            guard !text.isEmpty else { return hint(request.rule) ?? "Would change a file" }
            return PlainPath.isSecret(text)
                ? "Would change the secrets file \(PlainPath.short(text))" : "Would change \(PlainPath.short(text))"
        }
    }

    /// What the rule id says, when the action text does not.
    static func hint(_ rule: String?) -> String? {
        guard let rule = rule?.lowercased(), !rule.hasPrefix("rv.") else { return nil }
        let table: [(keys: [String], line: String)] = [
            (["reset-hard"], PlainCommand.resetHard),
            (["force-push", "push-force"], PlainCommand.rewriteRemote),
            (["clean"], PlainCommand.cleanUntracked),
            (["curl", "pipe", "remote-script"], PlainCommand.downloadedScript),
            (["rm-rf", "recursive-delete", "rm"], "Would delete files and folders"),
            (["secret", "credential", "dotenv"], "Would read a secrets file"),
            (["chmod", "world-writable"], "Would let anyone change files"),
            (["sudo"], "Would run a command with admin rights"),
            (["drop", "database"], "Would delete database data"),
        ]
        return table.first { entry in entry.keys.contains { rule.contains($0) } }?.line
    }
}

/// Shell command patterns. Matching is word-based on a rough split; the
/// line only explains, so a miss falls through to the generic line.
enum PlainCommand {
    static let resetHard = "Would throw away uncommitted changes"
    static let rewriteRemote = "Would rewrite the remote branch"
    static let cleanUntracked = "Would delete untracked files"
    static let downloadedScript = "Would run a script downloaded from the internet"
    static let adminSuffix = " with admin rights"

    static func explain(_ command: String) -> String? {
        guard !command.isEmpty else { return nil }
        let lower = command.lowercased()
        if runsDownloadedScript(lower) { return downloadedScript }
        for words in segments(command) {
            if let line = segment(words) { return line }
        }
        return sql(lower)
    }

    /// `curl … | sh`, `bash <(curl …)`, `sh -c "$(curl …)"`.
    static func runsDownloadedScript(_ lower: String) -> Bool {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "python", "python3", "node", "ruby", "perl"]
        let fetchers: Set<String> = ["curl", "wget"]
        let parts = lower.split(separator: "|").map { words(String($0)) }
        if let fetch = parts.firstIndex(where: { $0.contains { fetchers.contains($0) } }) {
            let later = parts.dropFirst(fetch + 1)
            if later.contains(where: { part in part.first(where: { $0 != "sudo" }).map(shells.contains) ?? false }) {
                return true
            }
        }
        return ["<(curl", "<(wget", "$(curl", "$(wget"].contains { lower.contains($0) }
            && words(lower).contains { shells.contains($0) }
    }

    /// Simple commands split on `&&`, `||`, `;`, `|` and newlines.
    static func segments(_ command: String) -> [[String]] {
        var text = command
        for separator in ["&&", "||", ";", "|", "\n"] {
            text = text.replacingOccurrences(of: separator, with: "\u{0}")
        }
        return text.split(separator: "\u{0}").map { words(String($0)) }.filter { !$0.isEmpty }
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()")) }
            .filter { !$0.isEmpty }
    }

    static func segment(_ input: [String]) -> String? {
        var words = Array(input.drop { isAssignment($0) })
        var admin = false
        while words.first == "sudo" {
            admin = true
            words = Array(words.dropFirst().drop { $0.hasPrefix("-") })
        }
        guard let first = words.first else { return nil }
        let name = (first.split(separator: "/").last.map(String.init) ?? first).lowercased()
        let args = Array(words.dropFirst())
        let line: String? = if args.contains(where: { ["db:drop", "db:reset"].contains($0.lowercased()) }) {
            "Would delete the database"
        } else {
            switch name {
            case "git": git(args)
            case "rm": rm(args)
            case "chmod": chmod(args)
            case "npm", "pnpm", "yarn", "bun": packages(name, args)
            case "pip", "pip3", "uv": pip(args)
            case "dropdb": "Would delete the database"
            default: nil
            }
        }
        guard admin else { return line }
        guard let line else { return "Would run \(words.joined(separator: " "))\(adminSuffix)" }
        return line.count + adminSuffix.count <= PlainLine.maxLength ? line + adminSuffix : line
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), let head = word.first else { return false }
        return head.isLetter && word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - git

    static func git(_ input: [String]) -> String? {
        var args = input[...]
        // Global options: `-C dir`, `-c key=value`, `--no-pager`.
        while let head = args.first, head.hasPrefix("-") {
            args = args.dropFirst(head == "-C" || head == "-c" ? 2 : 1)
        }
        guard let sub = args.first?.lowercased() else { return nil }
        let rest = Array(args.dropFirst())
        let flags = rest.filter { $0.hasPrefix("-") }
        let positional = rest.filter { !$0.hasPrefix("-") }
        switch sub {
        case "reset" where flags.contains("--hard"):
            return resetHard
        case "push":
            return push(flags: flags, positional: positional)
        case "clean" where shortFlag("f", in: flags) || flags.contains("--force"):
            return shortFlag("x", in: flags) || shortFlag("X", in: flags)
                ? "Would delete untracked and ignored files" : cleanUntracked
        case "checkout" where rest.contains("--") || positional == ["."]:
            return resetHard
        case "restore" where !flags.contains("--staged") && !positional.isEmpty:
            return resetHard
        case "branch" where flags.contains("-D") || (flags.contains("-d") && flags.contains("--force")):
            return positional.first.map { "Would delete the branch \($0)" } ?? "Would delete a branch"
        case "stash" where positional.first == "drop" || positional.first == "clear":
            return "Would throw away stashed changes"
        default:
            return nil
        }
    }

    static func push(flags: [String], positional: [String]) -> String? {
        let refspec = positional.count >= 2 ? positional.last : nil
        let branch = refspec.map(branchName)
        if flags.contains("--delete") || flags.contains("-d") || refspec?.hasPrefix(":") == true {
            return branch.map { "Would delete the remote branch \($0)" } ?? "Would delete a remote branch"
        }
        let forced = flags.contains { $0 == "-f" || $0.hasPrefix("--force") || $0 == "--mirror" }
            || refspec?.hasPrefix("+") == true
        guard forced else { return nil }
        return branch.map { "\(rewriteRemote) \($0)" } ?? rewriteRemote
    }

    static func branchName(_ refspec: String) -> String {
        var name = refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        if name.hasPrefix("refs/heads/") { name = String(name.dropFirst("refs/heads/".count)) }
        return name
    }

    /// `-fdx` holds `f`, `d` and `x`; long options do not count.
    static func shortFlag(_ letter: Character, in flags: [String]) -> Bool {
        flags.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains(letter) }
    }

    // MARK: - files

    static func rm(_ args: [String]) -> String? {
        let split = args.firstIndex(of: "--") ?? args.endIndex
        let flags = args[..<split].filter { $0.hasPrefix("-") }
        let targets = args[..<split].filter { !$0.hasPrefix("-") } + args[split...].dropFirst()
        guard !targets.isEmpty else { return nil }
        let recursive = shortFlag("r", in: flags) || shortFlag("R", in: flags) || flags.contains("--recursive")
        if targets.count > 1 {
            return recursive
                ? "Would delete \(targets.count) paths and everything in them"
                : "Would delete \(targets.count) files"
        }
        let target = targets[0]
        if recursive, ["/", "/*"].contains(target) { return "Would delete everything on this Mac" }
        let name = ["~", "~/", "$HOME"].contains(target) ? "your home folder" : PlainPath.short(target)
        return recursive ? "Would delete \(name) and everything in it" : "Would delete \(name)"
    }

    static func chmod(_ args: [String]) -> String? {
        let open = args.contains { ["777", "666", "a+w", "o+w", "a+rwx", "o+rwx"].contains($0) }
        guard open else { return nil }
        let recursive = shortFlag("R", in: args.filter { $0.hasPrefix("-") }) || args.contains("--recursive")
        let targets = args.filter { !$0.hasPrefix("-") && !["777", "666", "a+w", "o+w", "a+rwx", "o+rwx"].contains($0) }
        let name = targets.count == 1 ? PlainPath.short(targets[0]) : "files"
        return recursive ? "Would let anyone change \(name) and everything in it" : "Would let anyone change \(name)"
    }

    // MARK: - packages and databases

    static func packages(_ tool: String, _ args: [String]) -> String? {
        let verbs: Set<String> = ["install", "i", "add", "ci"]
        let positional = args.filter { !$0.hasPrefix("-") }
        let bareYarn = (tool == "yarn" || tool == "bun") && positional.isEmpty
        guard bareYarn || positional.first.map({ verbs.contains($0.lowercased()) }) == true else { return nil }
        let names = Array(positional.dropFirst())
        switch names.count {
        case 0: return "Would install the project's packages"
        case 1: return "Would add the package \(names[0]) to the project"
        default: return "Would add \(names.count) packages to the project"
        }
    }

    static func pip(_ args: [String]) -> String? {
        var positional = args.filter { !$0.hasPrefix("-") }
        if positional.first == "pip" { positional.removeFirst() }
        guard positional.first == "install" || positional.first == "add" else { return nil }
        let names = positional.dropFirst()
        return names.count == 1
            ? "Would add the Python package \(names[names.startIndex])"
            : "Would add Python packages"
    }

    static func sql(_ lower: String) -> String? {
        let words = words(lower).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ";`")) }
        for (index, word) in words.enumerated() where word == "drop" || word == "truncate" {
            var rest = words.dropFirst(index + 1)
            let kind = rest.first ?? ""
            if ["database", "schema"].contains(kind) { return "Would delete a whole database" }
            if word == "truncate" || kind == "table" {
                if kind == "table" { rest = rest.dropFirst() }
                if rest.starts(with: ["if", "exists"]) { rest = rest.dropFirst(2) }
                let verb = word == "drop" ? "delete" : "empty"
                return rest.first.map { "Would \(verb) the \($0) table" } ?? "Would \(verb) a database table"
            }
        }
        return nil
    }
}

/// Paths as the line shows them, and which ones hold secrets.
enum PlainPath {
    /// The last two components, so `~/.ssh/id_rsa` reads `.ssh/id_rsa`.
    static func short(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        let tail = parts.count > 2 ? parts.suffix(2).joined(separator: "/") : path
        return PlainText.clamp(tail, max: 40)
    }

    static func isSecret(_ path: String) -> Bool {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        if parts.dropLast().contains(where: { [".ssh", ".aws", ".gnupg", ".kube", ".docker"].contains($0) }) {
            return !name.hasSuffix(".pub")
        }
        if name == ".env" || name.hasPrefix(".env.") {
            return !["example", "sample", "template", "dist"].contains { name.hasSuffix(".\($0)") }
        }
        if name.hasPrefix("id_") { return !name.hasSuffix(".pub") }
        if [".netrc", ".npmrc", ".pypirc", "credentials", "credentials.json"].contains(name) { return true }
        return [".pem", ".key", ".p12", ".pfx"].contains { name.hasSuffix($0) }
    }
}

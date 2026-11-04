import Foundation
import RVDomain

/// Every simple command `raw` launches, as decoded argv words.
///
/// Segments come from `splitSegments` (chains, pipes, grouping, and
/// `$(...)`/backtick inners). Leading `NAME=value` assignments and plain
/// launchers (`sudo`, `env`, `command`, `exec`, `nohup`, `time`, `nice`,
/// `timeout`, `doas`, `builtin`) are dropped, argv0 is reduced to its
/// `commandName`, and `sh`/`bash`/`zsh -c` payloads recurse. Shared by the
/// inline-program and self-protection floors; never evaluates policy.
func launchedCommands(_ raw: String) -> [[String]] {
    launchedCommandHeads(raw).map(\.argv)
}

/// A launched command with the head word as written (before `commandName`),
/// so callers can tell a dynamic or glob head (`$RV`, `r?`) from a literal.
struct LaunchedCommand {
    let head: String
    let argv: [String]
}

func launchedCommandHeads(_ raw: String) -> [LaunchedCommand] {
    launchedCommandHeads(raw, depth: 0)
}

private let maxLaunchDepth = 8

private func launchedCommandHeads(_ raw: String, depth: Int) -> [LaunchedCommand] {
    guard depth < maxLaunchDepth else { return [] }
    var commands: [LaunchedCommand] = []
    for segment in splitSegments(raw) {
        let words = ShellPipeline.tokenize(segment)
            .filter { $0.isNewline == false }
            .map(\.lexeme)
        let (argv, payloads) = dropLaunchers(words)
        for payload in payloads {
            commands.append(contentsOf: launchedCommandHeads(payload, depth: depth + 1))
        }
        guard let head = argv.first else { continue }
        let program = commandName(head)
        if shellNames.contains(program),
           let flag = argv.dropFirst().firstIndex(where: isShellCommandFlag),
           let payload = argv.dropFirst(flag + 1).first(where: { $0.hasPrefix("-") == false })
        {
            commands.append(contentsOf: launchedCommandHeads(payload, depth: depth + 1))
            continue
        }
        if program == "eval" {
            commands.append(contentsOf: launchedCommandHeads(argv.dropFirst().joined(separator: " "), depth: depth + 1))
        }
        commands.append(LaunchedCommand(head: head, argv: [program] + argv.dropFirst()))
    }
    return commands
}

/// A command word as a case-insensitive filesystem resolves it: basename,
/// backslash-unescaped, then Unicode case-folded the way APFS folds
/// (`BASH`, `r\v`, `baſh`, `ﬁsh`). `lowercased()` alone misses `ſ`/`ﬁ`.
func commandName(_ word: String) -> String {
    unescapeBackslashPairs(basename(word)).folding(options: .caseInsensitive, locale: nil)
}

private let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish", "csh", "tcsh"]

private func isShellCommandFlag(_ word: String) -> Bool {
    word.hasPrefix("-") && word.hasPrefix("--") == false && word.hasSuffix("c")
}

/// Launchers whose next non-flag word is the real command.
let plainLaunchers: Set<String> = ["command", "exec", "nohup", "time", "builtin", "nice", "doas"]

/// Launcher flags that consume the following word as their value.
private let valuedLauncherFlags: [String: Set<String>] = [
    "sudo": ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"],
    "env": ["-u", "-C", "-S", "--unset", "--chdir"],
    "nice": ["-n"],
    "doas": ["-u", "-C"],
    "timeout": ["-s", "-k", "--signal", "--kill-after"],
    "exec": ["-a"],
]

/// Remaining argv plus `env -S` split-string payloads, which are command lines.
private func dropLaunchers(_ words: [String]) -> (argv: [String], payloads: [String]) {
    var index = 0
    var launcher: String?
    var payloads: [String] = []
    while index < words.count {
        let word = words[index]
        if isAssignmentWord(word) {
            index += 1
            continue
        }
        if launcher == "env", word.hasPrefix("-") {
            if word == "-S" || word == "--split-string" {
                if index + 1 < words.count { payloads.append(words[index + 1]) }
                index += 2
                continue
            }
            if word.hasPrefix("--split-string=") {
                payloads.append(String(word.dropFirst("--split-string=".count)))
                index += 1
                continue
            }
            if word.hasPrefix("-S"), word.hasPrefix("--") == false {
                payloads.append(String(word.dropFirst(2)))
                index += 1
                continue
            }
        }
        if let current = launcher, word.hasPrefix("-") {
            index += valuedLauncherFlags[current]?.contains(word) == true ? 2 : 1
            continue
        }
        if launcher == "timeout" {
            // The duration operand precedes the command.
            launcher = nil
            index += 1
            continue
        }
        let name = commandName(word)
        if name == "sudo" || name == "env" || name == "timeout" || plainLaunchers.contains(name) {
            launcher = name
            index += 1
            continue
        }
        break
    }
    return (Array(words[min(index, words.count)...]), payloads)
}

private func isAssignmentWord(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    let name = word[..<equals]
    guard let first = name.first, assignmentNameStart.contains(first) else { return false }
    return name.allSatisfy { assignmentNameChars.contains($0) }
}

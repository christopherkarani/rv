import RVDomain

/// Every simple command `raw` launches, as decoded argv words.
///
/// Segments come from `splitSegments` (chains, pipes, grouping, and
/// `$(...)`/backtick inners). Leading `NAME=value` assignments and plain
/// launchers (`sudo`, `env`, `command`, `exec`, `nohup`, `time`, `nice`,
/// `timeout`, `doas`, `builtin`) are dropped, argv0 is reduced to its
/// basename, and `sh`/`bash`/`zsh -c` payloads recurse. Shared by the
/// inline-program and self-protection floors; never evaluates policy.
func launchedCommands(_ raw: String) -> [[String]] {
    launchedCommands(raw, depth: 0)
}

private let maxLaunchDepth = 8

private func launchedCommands(_ raw: String, depth: Int) -> [[String]] {
    guard depth < maxLaunchDepth else { return [] }
    var commands: [[String]] = []
    for segment in splitSegments(raw) {
        let words = ShellPipeline.tokenize(segment)
            .filter { $0.isNewline == false }
            .map(\.lexeme)
        let argv = dropLaunchers(words)
        guard let head = argv.first else { continue }
        let program = unescapeBackslashPairs(basename(head))
        if shellNames.contains(program),
           let flag = argv.dropFirst().firstIndex(where: isShellCommandFlag),
           flag + 1 < argv.count
        {
            commands.append(contentsOf: launchedCommands(argv[flag + 1], depth: depth + 1))
            continue
        }
        commands.append([program] + argv.dropFirst())
    }
    return commands
}

private let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish"]

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

private func dropLaunchers(_ words: [String]) -> [String] {
    var index = 0
    var launcher: String?
    while index < words.count {
        let word = words[index]
        if isAssignmentWord(word) {
            index += 1
            continue
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
        let name = basename(word)
        if name == "sudo" || name == "env" || name == "timeout" || plainLaunchers.contains(name) {
            launcher = name
            index += 1
            continue
        }
        break
    }
    return Array(words[min(index, words.count)...])
}

private func isAssignmentWord(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    let name = word[..<equals]
    guard let first = name.first, assignmentNameStart.contains(first) else { return false }
    return name.allSatisfy { assignmentNameChars.contains($0) }
}

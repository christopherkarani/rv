import Foundation
import RVDomain

/// Peels for utility programs that run or hide another command:
/// `nohup`, `doas`, `find -exec`, `xargs`, and inline `perl`/`php`/`lua`/`awk`
/// programs. Returns nil when `head` is none of them.
func peelUtility(
    _ head: String,
    tokens: [ShellPipeline.Token],
    workingDirectory: WorkingDirectory?
) -> Peel? {
    switch head {
    case "nohup":
        return peelNohup(tokens, workingDirectory: workingDirectory)
    case "doas":
        return peelDoas(tokens, workingDirectory: workingDirectory)
    case "find":
        return peelFind(tokens, workingDirectory: workingDirectory)
    case "xargs":
        return peelXargs(tokens, workingDirectory: workingDirectory)
    default:
        return peelScriptInterpreter(head, tokens: tokens)
    }
}

private func peelNohup(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
    let rest = Array(tokens.dropFirst())
    if rest.isEmpty { return .notWrapper }
    return .next(renderCommand(rest), .nohup, workingDirectory)
}

private func peelDoas(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            index += 1
            break
        }
        if token == "-u" || token == "-C" {
            guard index + 1 < tokens.count else { return .limited(.doas) }
            index += 2
            continue
        }
        if token == "-s" {
            return .limited(.doas)
        }
        if token.hasPrefix("-") {
            index += 1
            continue
        }
        break
    }
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty { return .notWrapper }
    return .next(renderCommand(rest), .doas, workingDirectory)
}

// MARK: - find

private let findExecFlags: Set<String> = ["-exec", "-execdir", "-ok", "-okdir"]
private let findGlobalOptions: Set<String> = ["-H", "-L", "-P", "-E", "-X", "-x", "-s", "-d"]

private func peelFind(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel? {
    let words = tokens.map(\.lexeme)
    guard words.contains(where: { findExecFlags.contains($0) }) else { return nil }
    var index = 1
    while index < words.count, findGlobalOptions.contains(words[index]) {
        index += 1
    }
    var starts: [ShellPipeline.Token] = []
    while index < words.count, isFindStartPath(words[index]) {
        starts.append(tokens[index])
        index += 1
    }
    let execIndices = words.indices.filter { findExecFlags.contains(words[$0]) }
    guard execIndices.count == 1, let execIndex = execIndices.first else { return .limited(.find) }
    var inner: [ShellPipeline.Token] = []
    var terminated = false
    for token in tokens[(execIndex + 1)...] {
        if [";", "\\;", "+"].contains(token.lexeme) {
            terminated = true
            break
        }
        inner.append(token)
    }
    guard terminated, inner.isEmpty == false else { return .limited(.find) }
    let paths = starts.isEmpty ? [ShellPipeline.Token(lexeme: ".", wasQuoted: false)] : starts
    let substituted = inner.flatMap { token -> [ShellPipeline.Token] in
        token.lexeme == "{}" ? paths : [substitutePlaceholder(in: token, paths: paths)]
    }
    return .next(renderCommand(substituted), .find, workingDirectory)
}

private func isFindStartPath(_ word: String) -> Bool {
    guard let first = word.first else { return false }
    return ["-", "(", "!", ")"].contains(first) == false
}

private func substitutePlaceholder(
    in token: ShellPipeline.Token,
    paths: [ShellPipeline.Token]
) -> ShellPipeline.Token {
    guard token.lexeme.contains("{}"), let path = paths.first else { return token }
    var replaced = token
    replaced.lexeme = token.lexeme.replacingOccurrences(of: "{}", with: path.lexeme)
    return replaced
}

// MARK: - xargs

private let xargsValueFlags: Set<String> = ["-n", "-P", "-L", "-d", "-s", "-a", "-E", "-S"]

private func peelXargs(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    var replace: String?
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            index += 1
            break
        }
        if token == "-I" || token == "-J" {
            guard index + 1 < tokens.count else { return .limited(.xargs) }
            replace = tokens[index + 1].lexeme
            index += 2
            continue
        }
        if xargsValueFlags.contains(token) {
            guard index + 1 < tokens.count else { return .limited(.xargs) }
            index += 2
            continue
        }
        if token.hasPrefix("-I"), token.hasPrefix("--") == false, token.count > 2 {
            replace = String(token.dropFirst(2))
        }
        if token == "--replace" {
            replace = "{}"
        }
        if token.hasPrefix("--replace=") {
            replace = String(token.dropFirst("--replace=".count))
        }
        if token.hasPrefix("-") {
            index += 1
            continue
        }
        break
    }
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty { return .notWrapper }
    if xargsInnerIsMutating(rest.map(\.lexeme), replace: replace) {
        return .limited(.xargs)
    }
    return .next(renderCommand(rest), .xargs, workingDirectory)
}

private let xargsTransparentPrefixes: Set<String> = [
    "sudo", "doas", "env", "nohup", "nice", "command", "exec", "time", "timeout", "builtin", "ionice",
]

private let xargsMutatingVerbs: Set<String> = [
    "rm", "mv", "chmod", "chown", "chgrp", "dd", "shred", "truncate", "unlink", "rmdir", "ln",
    "cp", "install", "tee", "sed", "rsync", "tar", "touch", "mkdir", "ditto", "srm",
    "kill", "pkill", "killall",
]

private let xargsMutatingGit: Set<String> = [
    "reset", "checkout", "clean", "push", "restore", "switch", "branch", "tag", "stash",
    "rebase", "rm", "mv", "apply", "merge", "cherry-pick", "revert", "commit", "worktree",
]

private let xargsShells: Set<String> = ["bash", "sh", "zsh", "dash", "ksh"]

/// Stdin supplies unknowable trailing arguments, so a mutating program is
/// treated as unanalyzable. Read-only programs peel normally.
private func xargsInnerIsMutating(_ words: [String], replace: String?) -> Bool {
    guard let headIndex = words.firstIndex(where: isXargsEffectiveHead) else { return true }
    let head = unescapeBackslashPairs(basename(words[headIndex])).lowercased()
    let tail = words[(headIndex + 1)...]
    if xargsMutatingVerbs.contains(head) { return true }
    if head == "git" {
        return tail.contains { xargsMutatingGit.contains($0.lowercased()) }
    }
    if xargsShells.contains(head), let replace {
        return tail.contains { $0.contains(replace) }
    }
    return false
}

private func isXargsEffectiveHead(_ word: String) -> Bool {
    if word.hasPrefix("-") || word.contains("=") { return false }
    let digits = word.last.map { "smhd".contains($0) } == true ? String(word.dropLast()) : word
    if Double(digits) != nil { return false }
    return xargsTransparentPrefixes.contains(unescapeBackslashPairs(basename(word)).lowercased()) == false
}

// MARK: - perl / php / lua / awk

private func peelScriptInterpreter(_ head: String, tokens: [ShellPipeline.Token]) -> Peel? {
    let words = tokens.map(\.lexeme)
    if head == "perl" || head.hasPrefix("perl5") {
        return perlPrograms(words).contains(where: perlCodeCanSpawn) ? .limited(.perl) : nil
    }
    if head == "php" || head.hasPrefix("php7") || head.hasPrefix("php8") {
        return flagValues(words, flags: ["-r"]).contains(where: phpCodeCanSpawn) ? .limited(.php) : nil
    }
    if head == "lua" || head.hasPrefix("lua5") || head == "luajit" {
        return flagValues(words, flags: ["-e"]).contains(where: luaCodeCanSpawn) ? .limited(.lua) : nil
    }
    if ["awk", "gawk", "mawk", "nawk"].contains(head) {
        guard let program = awkProgram(words) else { return nil }
        return awkCodeCanSpawn(program) ? .limited(.awk) : nil
    }
    return nil
}

private func flagValues(_ words: [String], flags: Set<String>) -> [String] {
    var values: [String] = []
    for index in words.indices.dropFirst() where flags.contains(words[index]) && index + 1 < words.count {
        values.append(words[index + 1])
    }
    return values
}

/// `-e`/`-E` programs including clustered switches such as `-ne` and `-lane`.
private func perlPrograms(_ words: [String]) -> [String] {
    var values: [String] = []
    for index in words.indices.dropFirst() {
        let word = words[index]
        guard word.hasPrefix("-"), word.hasPrefix("--") == false, word.count >= 2 else { continue }
        let isProgramFlag = word.last == "e" || word.last == "E"
        let letters = word.dropFirst().allSatisfy { $0.isLetter }
        if isProgramFlag, letters, index + 1 < words.count {
            values.append(words[index + 1])
        }
    }
    return values
}

private func awkProgram(_ words: [String]) -> String? {
    var index = 1
    while index < words.count {
        let word = words[index]
        if word == "--" {
            return index + 1 < words.count ? words[index + 1] : nil
        }
        if word == "-e" || word == "--source" {
            return index + 1 < words.count ? words[index + 1] : nil
        }
        if word == "-f" || word == "-F" || word == "-v" {
            index += 2
            continue
        }
        if word.hasPrefix("-") {
            index += 1
            continue
        }
        return word
    }
    return nil
}

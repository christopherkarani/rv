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
        return peelScriptInterpreter(head, tokens: tokens, workingDirectory: workingDirectory)
    }
}

private func peelNohup(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
    var rest = Array(tokens.dropFirst())
    if rest.first?.lexeme == "--" { rest.removeFirst() }
    if rest.isEmpty { return .notWrapper }
    return .next(renderCommand(rest), .nohup, workingDirectory)
}

private let doasValueLetters: Set<Character> = ["u", "C"]

/// True when the short-flag word `token` (`-u`, `-nu`, `-Eu`) ends in a
/// flag that takes its value from the next word. A value letter followed by
/// more characters has its value attached (`-uroot`) and consumes nothing.
func shortClusterConsumesValue(_ token: String, valueLetters: Set<Character>) -> Bool {
    guard token.hasPrefix("-"), token.hasPrefix("--") == false else { return false }
    let letters = token.dropFirst()
    guard let position = letters.firstIndex(where: { valueLetters.contains($0) }) else { return false }
    return letters.index(after: position) == letters.endIndex
}

private func peelDoas(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            index += 1
            break
        }
        if shortClusterConsumesValue(token, valueLetters: doasValueLetters) {
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

/// Short flags whose value is the rest of the word or the next word.
private let xargsValueLetters: Set<Character> = ["n", "P", "L", "d", "s", "a", "E", "S", "R"]
/// Short flags whose value, if any, must be attached (`-l5`, `-eEOF`).
private let xargsOptionalLetters: Set<Character> = ["l", "e"]
/// Long options that need a value, as `--opt=value` or `--opt value`.
private let xargsLongValueOptions: Set<String> = [
    "arg-file", "delimiter", "max-args", "max-chars", "max-procs", "process-slot-var",
]
/// Long options whose value, if any, must be attached with `=`.
private let xargsLongOptionalOptions: Set<String> = ["eof", "replace", "max-lines"]
private let xargsLongFlags: Set<String> = [
    "null", "no-run-if-empty", "verbose", "interactive", "exit", "open-tty",
    "show-limits", "help", "version",
]

private func peelXargs(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    var replace: String?
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            index += 1
            break
        }
        guard token.hasPrefix("-"), token != "-" else { break }
        if token.hasPrefix("--") {
            guard let step = xargsLongOption(token, next: tokens[(index + 1)...].first?.lexeme) else {
                return .limited(.xargs)
            }
            replace = step.replace ?? replace
            index += step.width
            continue
        }
        guard let step = xargsShortCluster(token, next: tokens[(index + 1)...].first?.lexeme) else {
            return .limited(.xargs)
        }
        replace = step.replace ?? replace
        index += step.width
    }
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty { return .notWrapper }
    if xargsInnerIsMutating(rest.map(\.lexeme), replace: replace) {
        return .limited(.xargs)
    }
    return .next(renderCommand(rest), .xargs, workingDirectory)
}

private struct XargsOptionStep {
    /// Words consumed: 1, or 2 when the option took the next word.
    var width: Int
    var replace: String?
}

private func xargsLongOption(_ token: String, next: String?) -> XargsOptionStep? {
    let body = token.dropFirst(2)
    let name = String(body.prefix { $0 != "=" })
    let attached = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
    if xargsLongValueOptions.contains(name) {
        if attached != nil { return XargsOptionStep(width: 1, replace: nil) }
        return next == nil ? nil : XargsOptionStep(width: 2, replace: nil)
    }
    if xargsLongOptionalOptions.contains(name) {
        let replacement = name == "replace" ? (attached.flatMap { $0.isEmpty ? nil : $0 } ?? "{}") : nil
        return XargsOptionStep(width: 1, replace: replacement)
    }
    return xargsLongFlags.contains(name) ? XargsOptionStep(width: 1, replace: nil) : nil
}

/// Walks a short-flag word such as `-0`, `-n1`, `-0I`, `-i`, `-iX`.
/// `-I`/`-J` name the replacement string, GNU `-i` defaults it to `{}`.
private func xargsShortCluster(_ token: String, next: String?) -> XargsOptionStep? {
    let letters = Array(token.dropFirst())
    for (offset, letter) in letters.enumerated() {
        let attached = String(letters[(offset + 1)...])
        if letter == "I" || letter == "J" {
            if attached.isEmpty == false { return XargsOptionStep(width: 1, replace: attached) }
            return next.map { XargsOptionStep(width: 2, replace: $0) }
        }
        if letter == "i" {
            return XargsOptionStep(width: 1, replace: attached.isEmpty ? "{}" : attached)
        }
        if xargsValueLetters.contains(letter) {
            if attached.isEmpty == false { return XargsOptionStep(width: 1, replace: nil) }
            return next == nil ? nil : XargsOptionStep(width: 2, replace: nil)
        }
        if xargsOptionalLetters.contains(letter) {
            return XargsOptionStep(width: 1, replace: nil)
        }
    }
    return XargsOptionStep(width: 1, replace: nil)
}

private let xargsTransparentPrefixes: Set<String> = plainLaunchers.union(["sudo", "env", "timeout", "ionice"])

private let xargsMutatingVerbs: Set<String> = [
    "rm", "mv", "chmod", "chown", "chgrp", "dd", "shred", "truncate", "unlink", "rmdir", "ln",
    "cp", "install", "tee", "rsync", "tar", "touch", "mkdir", "ditto", "srm",
    "kill", "pkill", "killall",
]

private let xargsMutatingGit: Set<String> = [
    "reset", "checkout", "clean", "push", "restore", "switch", "branch", "tag", "stash",
    "rebase", "rm", "mv", "apply", "merge", "cherry-pick", "revert", "commit", "worktree",
]

private let xargsShells: Set<String> = ["bash", "sh", "zsh", "dash", "ksh"]

/// Stdin supplies unknowable trailing arguments, so a mutating program is
/// treated as unanalyzable. Read-only programs peel normally.
private func xargsInnerIsMutating(_ original: [String], replace: String?, depth: Int = 0) -> Bool {
    let words = dropXargsLauncherPrefixes(original)
    guard depth < 4 else { return true }
    if let peeled = xargsPeeledWords(words) {
        // Wrapper flags carry values (`sudo -u root rm`), so the real head
        // comes from the shared unwrap, not from skipping `-` words.
        if peeled.limited || xargsInnerIsMutating(peeled.words, replace: replace, depth: depth + 1) {
            return true
        }
    }
    guard let headIndex = words.firstIndex(where: isXargsEffectiveHead) else { return true }
    let head = unescapeBackslashPairs(basename(words[headIndex])).lowercased()
    let tail = words[(headIndex + 1)...]
    if xargsMutatingVerbs.contains(head) { return true }
    if head == "sed" { return tail.contains(where: isSedInPlaceFlag) }
    if head == "perl" { return perlSwitchScan(Array(tail)).inPlace }
    if head == "git" {
        return tail.contains { xargsMutatingGit.contains($0.lowercased()) }
    }
    if xargsShells.contains(head), let replace {
        return tail.contains { $0.contains(replace) }
    }
    return false
}

/// `stdbuf [-i|-o|-e MODE]… cmd` and `busybox applet …` run the next word as
/// the command; their own words must not be mistaken for it.
private func dropXargsLauncherPrefixes(_ words: [String]) -> [String] {
    var rest = words[...]
    while let first = rest.first {
        let name = unescapeBackslashPairs(basename(first)).lowercased()
        if name == "busybox" {
            rest = rest.dropFirst()
        } else if name == "stdbuf" {
            rest = rest.dropFirst()
            while let flag = rest.first, flag.hasPrefix("-"), flag != "--" {
                rest = rest.dropFirst()
                if ["-i", "-o", "-e", "--input", "--output", "--error"].contains(flag), rest.isEmpty == false {
                    rest = rest.dropFirst()
                }
            }
            if rest.first == "--" { rest = rest.dropFirst() }
        } else {
            break
        }
    }
    return Array(rest)
}

/// The command left after peeling known wrappers, `limited` when the unwrap
/// cannot decide; nil when `words` is not a wrapper invocation.
private func xargsPeeledWords(_ words: [String]) -> (words: [String], limited: Bool)? {
    guard words.isEmpty == false else { return nil }
    let text = renderCommand(words.map { ShellPipeline.Token(lexeme: $0, wasQuoted: false) })
    switch ShellPipeline.unwrap(
        text, workingDirectory: nil, budget: .default, depth: 0, layers: [], splitChains: false
    ) {
    case .limited:
        return ([], true)
    case .complete(let unwrapped):
        guard unwrapped.layers.isEmpty == false else { return nil }
        return (ShellPipeline.tokenize(unwrapped.command.rawValue).map(\.lexeme), false)
    }
}

/// `-i`, `-i.bak`, `-ni`, `-Ei`, `--in-place[=SUFFIX]`: sed only writes
/// files in place; otherwise it filters its input.
private func isSedInPlaceFlag(_ word: String) -> Bool {
    if word.hasPrefix("--") { return "--in-place".hasPrefix(word.prefix { $0 != "=" }) && word.count >= 4 }
    return word.hasPrefix("-") && (word.dropFirst().contains("i") || word.dropFirst().contains("I"))
}

private func isXargsEffectiveHead(_ word: String) -> Bool {
    if word.hasPrefix("-") || word.contains("=") { return false }
    let digits = word.last.map { "smhd".contains($0) } == true ? String(word.dropLast()) : word
    if Double(digits) != nil { return false }
    return xargsTransparentPrefixes.contains(unescapeBackslashPairs(basename(word)).lowercased()) == false
}

// MARK: - perl / php / lua / awk

private func peelScriptInterpreter(
    _ head: String,
    tokens: [ShellPipeline.Token],
    workingDirectory: WorkingDirectory?
) -> Peel? {
    let words = tokens.map(\.lexeme)
    if head == "perl" || head.hasPrefix("perl5") {
        if perlPrograms(words).contains(where: perlCodeCanSpawn) { return .limited(.perl) }
        let edited = parsePerl(Argv(program: head, args: Array(words.dropFirst())))?.paths ?? []
        return writeProxy(edited, .perl, workingDirectory)
    }
    if head == "php" || head.hasPrefix("php7") || head.hasPrefix("php8") {
        return flagValues(words, flags: ["-r"]).contains(where: phpCodeCanSpawn) ? .limited(.php) : nil
    }
    if head == "lua" || head.hasPrefix("lua5") || head == "luajit" {
        return flagValues(words, flags: ["-e"]).contains(where: luaCodeCanSpawn) ? .limited(.lua) : nil
    }
    if head == "sed" || head == "gsed" {
        let args = Array(words.dropFirst())
        if sedScriptFileIsUnreadable(args) { return .limited(.sed) }
        let effects = sedScriptTexts(args).map(sedScriptEffects)
        if effects.contains(where: { $0.executes || $0.unparseable }) { return .limited(.sed) }
        return writeProxy(sedScriptWrites(args), .sed, workingDirectory)
    }
    if ["awk", "gawk", "mawk", "nawk"].contains(head) {
        let sources = awkSources(words)
        if sources.readsStdin || sources.programs.contains(where: awkCodeCanSpawn) { return .limited(.awk) }
        guard awkRequestsInPlace(words) else { return nil }
        let files = awkFileOperands(words)
        return files.isEmpty ? .limited(.awk) : writeProxy(files, .awk, workingDirectory)
    }
    return nil
}

/// gawk `-i inplace` / `--include=inplace` rewrites its file operands.
private func awkRequestsInPlace(_ words: [String]) -> Bool {
    for (index, word) in words.enumerated().dropFirst() {
        if word == "-iinplace" || word == "--include=inplace" { return true }
        if word == "-i" || word == "--include", index + 1 < words.count, words[index + 1] == "inplace" {
            return true
        }
    }
    return false
}

/// The file operands of an awk invocation: words after the options and the
/// program (unless `-f`/`--file`/`--source` gave it), less `var=value`.
private func awkFileOperands(_ words: [String]) -> [String] {
    let valueFlags: Set<String> = ["-F", "-v", "-f", "-i", "-e", "-E", "-l", "--file", "--include", "--source",
                                   "--field-separator", "--assign", "--load"]
    var operands: [String] = []
    var programGiven = false
    var index = 1
    while index < words.count {
        let word = words[index]
        index += 1
        if word == "--" {
            operands += words[index...]
            break
        }
        if word.hasPrefix("-"), word.count > 1 {
            if ["-f", "--file", "-e", "--source"].contains(word) || word.hasPrefix("--file=")
                || word.hasPrefix("--source=") || (word.hasPrefix("-f") && word.count > 2)
            {
                programGiven = true
            }
            if valueFlags.contains(word) { index += 1 }
            continue
        }
        operands.append(word)
    }
    if programGiven == false, operands.isEmpty == false { operands.removeFirst() }
    return operands.filter { $0.contains("=") == false || $0.hasPrefix("/") || $0.hasPrefix(".") }
}

/// Files a sed invocation writes because of its script (`w`, `s///w`) plus
/// the `-i` operands; empty when the script writes nothing, so plain
/// `sed -i` keeps its view-based parse.
private func sedScriptWrites(_ args: [String]) -> [String] {
    let scripted = sedScriptTexts(args).flatMap { sedScriptEffects($0).writeTargets }
    guard scripted.isEmpty == false else { return [] }
    var paths = parseSed(args)?.paths ?? []
    for target in scripted where paths.contains(target) == false { paths.append(target) }
    return paths
}

/// Peels a program whose view-masked script hides its file writes into the
/// equivalent `tee -- <paths>`, which the filesystem analysis already
/// classifies (outside the repo denies, inside allows). Nil for no paths.
private func writeProxy(_ paths: [String], _ kind: WrapperKind, _ workingDirectory: WorkingDirectory?) -> Peel? {
    guard paths.isEmpty == false else { return nil }
    return .next(writeProxyCommand(paths), kind, workingDirectory)
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

private struct AwkSources {
    /// Inline programs: every `-e`/`--source`, or the first operand.
    var programs: [String] = []
    /// A program file that is stdin (`-f -`, `-f /dev/stdin`): unknowable.
    var readsStdin = false
}

private func awkSources(_ words: [String]) -> AwkSources {
    var sources = AwkSources()
    var hasSource = false
    var index = 1
    func note(file: String) {
        hasSource = true
        let dynamic = file.hasPrefix("<(") || file.contains("$(") || file.contains("`")
        if file == "-" || file.hasPrefix("/dev/") || file.hasPrefix("/proc/") || dynamic { sources.readsStdin = true }
    }
    while index < words.count {
        let word = words[index]
        let next = index + 1 < words.count ? words[index + 1] : nil
        if word == "--" {
            if hasSource == false, let next { sources.programs.append(next) }
            return sources
        }
        if word == "-e" || word == "--source" {
            hasSource = true
            if let next { sources.programs.append(next) }
            index += 2
        } else if word.hasPrefix("--source=") {
            hasSource = true
            sources.programs.append(String(word.dropFirst("--source=".count)))
            index += 1
        } else if ["-f", "-E", "--file", "--exec"].contains(word) {
            note(file: next ?? "-")
            index += 2
        } else if word.hasPrefix("--file=") || word.hasPrefix("--exec=") {
            note(file: String(word.drop { $0 != "=" }.dropFirst()))
            index += 1
        } else if word.hasPrefix("-f"), word.hasPrefix("--") == false {
            note(file: String(word.dropFirst(2)))
            index += 1
        } else if ["-F", "-v", "-i", "-l", "-W"].contains(word) {
            index += 2
        } else if word.hasPrefix("-") {
            index += 1
        } else {
            if hasSource == false { sources.programs.append(word) }
            return sources
        }
    }
    return sources
}

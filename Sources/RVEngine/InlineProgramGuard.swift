import RVDomain

/// Packs-only floor for inline interpreter programs.
///
/// Matching masks quoted interpreter payloads (`perl -e '…'`, awk
/// programs, sed scripts) as data, so the packs cannot see what such a
/// program does; only the judge reads them. `requiresJudge` is true when
/// an inline program (perl/php/lua/ruby/python/node eval flags, any awk
/// program, a sed `e` command or `s///e` flag) carries a process-spawn,
/// eval, filesystem-delete, or secret-path marker. The judge gate turns
/// that into indeterminate when no judge can score the command; with a
/// judge loaded the marker is not consulted. Over-approximate by design:
/// a hit never denies, it only withholds a packs-only allow.
public enum InlineProgramGuard {
    public static func requiresJudge(
        _ command: ShellCommand,
        secrets: SecretPathCatalog = .dayOne
    ) -> Bool {
        let inline = launchedCommands(command.rawValue).contains { argv in
            guard let payload = inlineProgram(argv) else { return false }
            switch payload {
            case .script(let kind, let text):
                return scriptIsRisky(text, kind: kind, secrets: secrets)
            case .sed(let scripts):
                return scripts.contains { sedExecutes($0) || mentionsSecretPath($0, secrets: secrets) }
            }
        }
        return inline || stdinProgramRequiresJudge(command.rawValue, secrets: secrets)
    }
}

enum ProgramKind {
    case shellQuoting // perl, ruby, php: backticks run a shell
    case plain // python, node, lua
    case awk
}

enum InlineProgram {
    case script(ProgramKind, String)
    case sed([String])
}

/// The inline program text an argv runs, or nil when it runs none.
func inlineProgram(_ argv: [String]) -> InlineProgram? {
    guard let program = argv.first?.lowercased() else { return nil }
    let args = Array(argv.dropFirst())
    let body = args.joined(separator: " ")
    if awkNames.contains(program) {
        return .script(.awk, body)
    }
    if sedNames.contains(program) {
        return .sed(sedScripts(args))
    }
    if isPythonExecutable(program) {
        return args.contains(where: { isBundledFlag($0, letters: "c") }) ? .script(.plain, body) : nil
    }
    if isNodeExecutable(program) || program == "bun" || program == "deno" {
        let inline = args.contains { arg in
            ["-e", "-p", "-pe", "-ep", "--eval", "--print", "eval"].contains(arg)
                || arg.hasPrefix("--eval=") || arg.hasPrefix("--print=")
        }
        return inline ? .script(.plain, body) : nil
    }
    if isLuaExecutable(program) {
        return args.contains(where: { isBundledFlag($0, letters: "e") }) ? .script(.plain, body) : nil
    }
    if isPerlExecutable(program) || isRubyExecutable(program) {
        return args.contains(where: { isBundledFlag($0, letters: "eE") }) ? .script(.shellQuoting, body) : nil
    }
    if isPHPExecutable(program) {
        return args.contains(where: { isBundledFlag($0, letters: "rBRE") }) ? .script(.shellQuoting, body) : nil
    }
    return nil
}

private let awkNames: Set<String> = ["awk", "gawk", "mawk", "nawk"]
private let sedNames: Set<String> = ["sed", "gsed"]

/// `-e`, `-ne`, `-lane`, `-ecode`: a single-dash word carrying one of `letters`.
private func isBundledFlag(_ word: String, letters: String) -> Bool {
    guard word.hasPrefix("-"), word.hasPrefix("--") == false, word.count > 1 else { return false }
    return word.dropFirst().prefix(while: { $0.isLetter }).contains(where: { letters.contains($0) })
}

/// Script operands: `-e`/`--expression` values, else the first operand.
private func sedScripts(_ args: [String]) -> [String] {
    var scripts: [String] = []
    var operands: [String] = []
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg == "-e" || arg == "--expression", index + 1 < args.count {
            scripts.append(args[index + 1])
            index += 2
            continue
        }
        if arg.hasPrefix("--expression=") {
            scripts.append(String(arg.dropFirst("--expression=".count)))
        } else if arg.hasPrefix("-") == false {
            operands.append(arg)
        }
        index += 1
    }
    if scripts.isEmpty, let first = operands.first {
        scripts.append(first)
    }
    return scripts
}

/// GNU sed runs a shell for the `e` command and the `s///e` flag.
private func sedExecutes(_ script: String) -> Bool {
    let chars = Array(script)
    for (index, char) in chars.enumerated() where char == "e" {
        let before = index == 0 ? nil : chars[index - 1]
        let after = index + 1 < chars.count ? chars[index + 1] : nil
        let endsCommand = after == nil || after == " " || after == ";" || after == "}" || after == "\n"
        guard endsCommand else { continue }
        // `e` command: at a command position (start, after `;`/`{`/newline,
        // or after an address such as `1`, `$`, `/re/`).
        guard let before else { return true }
        if before == ";" || before == "{" || before == "\n" || before == " " || before.isNumber
            || before == "$" || before == "/" || before == "!"
        {
            return true
        }
        // `s///e` with other flags first (`s/a/b/ge`).
        if "gpiImM0123456789".contains(before), substituteFlagRun(chars, endingAt: index) {
            return true
        }
    }
    return false
}

private func substituteFlagRun(_ chars: [Character], endingAt index: Int) -> Bool {
    var cursor = index - 1
    while cursor >= 0, "gpiImM0123456789".contains(chars[cursor]) {
        cursor -= 1
    }
    return cursor >= 0 && chars[cursor] == "/"
}

func scriptIsRisky(_ text: String, kind: ProgramKind, secrets: SecretPathCatalog) -> Bool {
    if identifierWords(text).contains(where: { riskyIdentifiers.contains($0) }) { return true }
    if riskySubstrings.contains(where: { text.contains($0) }) { return true }
    switch kind {
    case .shellQuoting:
        if text.contains("`") || text.contains("%x") { return true }
    case .awk:
        if awkPipesCommand(text) { return true }
    case .plain:
        break
    }
    return mentionsSecretPath(text, secrets: secrets)
}

/// Process spawn, dynamic eval, and filesystem-delete entry points across
/// perl, php, lua, ruby, python, node, and awk. Matched as whole words.
private let riskyIdentifiers: Set<String> = [
    // spawn
    "system", "exec", "execv", "execve", "execvp", "execvpe", "execl", "execlp", "execle",
    "execSync", "execFile", "execFileSync", "spawn", "spawnSync", "spawnv", "spawnve",
    "spawnl", "spawnlp", "spawnvp", "posix_spawn", "popen", "popen2", "popen3", "fork",
    "forkpty", "subprocess", "pty", "PTY", "child_process", "proc_open", "shell_exec",
    "passthru", "pcntl_exec", "qx", "readpipe", "Open3", "syscall",
    // dynamic eval / import indirection
    "eval", "__import__", "getattr", "importlib",
    "runInNewContext", "runInThisContext", "runInContext", "dlopen", "ctypes",
    // filesystem delete
    "rmSync", "rmdirSync", "rmdir", "unlink", "unlinkSync", "unlinkat", "rmtree",
    "rm_rf", "rm_r", "rm_f", "removedirs", "remove_entry", "remove_entry_secure",
    "remove_dir_all", "truncate", "truncateSync", "ftruncate", "shred", "rimraf",
    "FileUtils",
]

private let riskySubstrings: [String] = [
    "os.execute", "os.remove", ".rm(", "File.delete", "Function(", "\"-|\"", "\"|-\"",
]

private func identifierWords(_ text: String) -> Set<String> {
    var words: Set<String> = []
    var current = ""
    for char in text {
        if char == "_" || (char.isASCII && (char.isLetter || char.isNumber)) {
            current.append(char)
        } else if current.isEmpty == false {
            words.insert(current)
            current = ""
        }
    }
    if current.isEmpty == false { words.insert(current) }
    return words
}

/// awk `print | "cmd"`, `"cmd" | getline`, and gawk `|&` coprocesses.
private func awkPipesCommand(_ text: String) -> Bool {
    let chars = Array(text)
    for (index, char) in chars.enumerated() where char == "|" {
        var cursor = index + 1
        if cursor < chars.count, chars[cursor] == "&" { return true }
        while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
        guard cursor < chars.count else { continue }
        if chars[cursor] == "\"" { return true }
        if String(chars[cursor...]).hasPrefix("getline") { return true }
    }
    return false
}

/// Path-shaped words inside the program that a secret-path rule matches.
private func mentionsSecretPath(_ text: String, secrets: SecretPathCatalog) -> Bool {
    let separators: Set<Character> = [" ", "\t", "\n", "'", "\"", "(", ")", "[", "]", "{", "}", ",", ";", "=", "`", "+"]
    return text.split(whereSeparator: { separators.contains($0) }).contains { piece in
        let candidate = String(piece)
        guard candidate.contains("/") || candidate.hasPrefix(".") || candidate.hasPrefix("~") else {
            return false
        }
        return secrets.firstMatch(of: candidate) != nil
    }
}

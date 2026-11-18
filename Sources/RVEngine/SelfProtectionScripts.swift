import RVDomain

// Routes into rv that the launcher parser (`launchedCommandHeads`) does not
// follow: a script an interpreter or runner executes, the command
// `find -exec` runs, and a program a shell or interpreter reads from
// stdin. Script text is not parsed; it is scanned as opaque text for a
// literal rv binary together with a weakening word. That misses rv built
// at run time (`"r" + "v"`, `rv $cmd` with the verb from nowhere on the
// line); rvd's owner authentication still guards the real mutation.

// MARK: - Opaque scripts

/// Interpreters and debuggers/editors that run code from an operand, a
/// flag, or stdin, beyond `isInterpreterExecutable`.
private let interpreterNames: Set<String> = [
    "bun", "deno", "tsx", "ts-node", "osascript", "expect", "tclsh", "wish", "rscript", "r", "julia",
    "raku", "perl6", "irb", "jruby", "gdb", "lldb", "vim", "nvim", "vi", "ex", "emacs",
]

/// Programs that hand their operands, or their stdin, to a shell: as
/// another user (`su -c`), on another host (`ssh host cmd`), on a timer
/// (`watch`, `crontab -`, `at`), in a detached terminal (`tmux new cmd`),
/// or per file (`fd -x`).
private let shellRunnerNames: Set<String> = [
    "su", "runuser", "sg", "pkexec", "ssh", "watch", "tmux", "screen", "script", "chroot", "unshare",
    "nsenter", "systemd-run", "parallel", "dtach", "fd", "fdfind", "crontab", "at", "batch",
]

/// A shell runner. `fd` counts with or without a visible `-x`: an escaped
/// or expanded flag (`\-x`, `$X`) is not worth modelling (fail closed).
private func isShellRunner(_ argv: [String]) -> Bool {
    argv.first.map(shellRunnerNames.contains) ?? false
}

private func isInterpreter(_ program: String) -> Bool {
    // `python3.13t`, `pypy3`: free-threaded and alternative builds.
    isInterpreterExecutable(program) || program.hasPrefix("python") || program.hasPrefix("pypy")
        || awkNames.contains(program) || interpreterNames.contains(program)
}

/// The text an interpreter or shell runner would execute, as every operand
/// joined (a superset of its script), or nil when `launched` runs none. A
/// dynamic head may be either; a sed script counts only with an `e`
/// command or `s///e` flag.
func opaqueScriptText(_ launched: LaunchedCommand) -> String? {
    let argv = launched.guardArgv
    guard let program = argv.first else { return nil }
    if launched.headIsDynamic || isInterpreter(program) || isShellRunner(argv) {
        return argv.dropFirst().joined(separator: " ")
    }
    if case .sed(let scripts)? = inlineProgram(argv) {
        let executing = scripts.filter(sedExecutes)
        return executing.isEmpty ? nil : executing.joined(separator: " ")
    }
    return nil
}

/// A script whose rv words may come from elsewhere on the line: it names
/// an rv binary (`awk '{system("rv " $0)}'`), spawns or evals (`perl -ne
/// 'system $_'`), loads or reads code or words from stdin, a descriptor or
/// the environment (`do "/dev/stdin"`, `runpy`, `$ENV{V}`), runs with an
/// assignment (`V=x python3 -c …`), or is a sed `e`, a runner, or a dynamic
/// head. The caller then scans the whole line. Reading stdin as data
/// (`json.load(sys.stdin)`) cannot be told apart from running it without
/// a denylist an agent can dodge, so it counts too.
func scriptReachesPastItself(_ launched: LaunchedCommand) -> Bool {
    guard let script = opaqueScriptText(launched), let program = launched.guardArgv.first else { return false }
    if launched.headIsDynamic || isShellRunner(launched.guardArgv) || isInterpreter(program) == false
        || launched.assignments.isEmpty == false
    {
        return true
    }
    if scriptViews(script).contains(where: { scriptTokens($0).contains(where: namesRVBinary) }) { return true }
    if outsideInputMarkers.contains(where: script.contains) { return true }
    if codeIdentifiers(script).contains(where: loaderIdentifiers.contains) { return true }
    return scriptIsRisky(script, kind: programKind(program), secrets: noSecretPaths)
}

/// Text through which a script takes input from outside its own text:
/// stdin, a descriptor, a URL wrapper, the environment, a pipe open.
private let outsideInputMarkers: [String] = [
    "stdin", "STDIN", "/dev/", "/proc/", "php://", "io.read", "ENV", "environ", "getenv", "process.env", "ARGF",
    "$<", "<>", "<&", "|\"", "\"|", "|'", "'|",
]

/// Calls that load and run code, or start a process, beyond
/// `scriptIsRisky`'s list, and deserializers that can run code.
private let loaderIdentifiers: Set<String> = [
    "pickle", "marshal", "yaml", "dill", "shelve", "gets", "input", "readline", "readlines", "breakpoint",
    "interact", "runsource", "runcode",
    "do", "load", "require", "require_once", "include", "include_once", "run_path", "run_module", "runpy",
    "compile", "exec_module", "import_module", "loadfile", "dofile", "loadstring", "posix_spawnp",
    "create_subprocess_shell", "create_subprocess_exec", "instance_eval", "class_eval", "module_eval", "send",
    "source",
]

private func codeIdentifiers(_ text: String) -> Set<String> {
    Set(text.split(whereSeparator: { ($0.isASCII && ($0.isLetter || $0.isNumber)) == false && $0 != "_" })
        .map(String.init))
}

private let noSecretPaths = SecretPathCatalog(rules: [])

private func programKind(_ program: String) -> ProgramKind {
    if awkNames.contains(program) { return .awk }
    if program == "osascript" { return .appleScript }
    if isPerlExecutable(program) || isRubyExecutable(program) || isPHPExecutable(program) || program == "irb"
        || program == "jruby"
    {
        return .shellQuoting
    }
    return .plain
}

/// Words a weakening rv invocation needs literally (`isWeakeningVerb` /
/// `isWeakeningSub`): every verb, and the subcommands and flags that are
/// not everyday code words. `set`, `add`, `remove`, `import`, `apply`,
/// `mode`, `hook` and `sign` are left out: in a literal invocation they
/// follow a verb that is listed (`secrets import`, `allowlist add`), and
/// alone they would flag any one-liner that imports a module. Matched
/// case-sensitively, as the CLI parses them.
private let scriptWeakeningWords: Set<String> = subcommandVerbs.union([
    "uninstall", "setup", "--observe", "--save", "draft", "rollback", "disable", "add-command",
    "redeem", "mint", "approve", "trust", "oauth-reset", "ceiling",
])

/// True when `text`, read as opaque script, names an rv binary (`rv`,
/// `rv-cli`, any path ending in one) and a weakening word, in any view.
func carriesWeakeningRV(_ text: String) -> Bool {
    let views = scriptViews(text)
    let namingRV = views.filter { scriptTokens($0).contains(where: namesRVBinary) }
    if namingRV.contains(where: { scriptTokens($0).contains(where: holdsWeakeningWord) }) { return true }
    // Named characters (`\N{…}`) and Perl case escapes (`\L…`, `\l`) are not
    // decoded: with rv named, they may spell a verb. Fail closed.
    return namingRV.isEmpty == false && undecodedEscapes.contains(where: text.contains)
}

private let undecodedEscapes = ["\\N{", "\\L", "\\l"]

/// `text` as written; with escapes decoded (`rv\x20uninstall`, printf's
/// `\\` and `\n`); and each of those with line continuations joined and
/// quoting removed (`r''v`, `"r""v"`, `'r'$'v'`, `r\v`, `r\<LF>v`); and with
/// every letter escape read as a blank (`\cI`, Ruby's `\s`); and with
/// braced escapes decoded (`\x{75}`, `\u{75}`). Views without `rv` in any
/// case are dropped before tokenizing: every rv token holds it.
private func scriptViews(_ text: String) -> [String] {
    let decoded = decodingAnsiCEscapes(text)
    let views = [
        text, decoded, unquoted(joinedContinuations(text)), unquoted(joinedContinuations(decoded)),
        unquoted(blankingLetterEscapes(text)), unquoted(decodingBracedEscapes(text)),
    ]
    return views.filter { $0.lowercased().contains("rv") }
}

private func joinedContinuations(_ text: String) -> String {
    text.replacingOccurrences(of: "\\\n", with: "")
}

/// Quotes, backticks, backslashes, and the `$` that opens `$'…'`/`$"…"`.
private func unquoted(_ text: String) -> String {
    var out = ""
    var previous: Character?
    for char in text {
        defer { previous = char }
        if "'\"`\\".contains(char) {
            if previous == "$" { out.removeLast() }
            continue
        }
        out.append(char)
    }
    return out
}

/// `\cX` and `\<letter>` become a blank: in some language they are one.
private func blankingLetterEscapes(_ text: String) -> String {
    var out = ""
    var iterator = text.makeIterator()
    while let char = iterator.next() {
        guard char == "\\", let next = iterator.next() else {
            out.append(char)
            continue
        }
        if next == "c" {
            _ = iterator.next()
            out.append(" ")
        } else if next.isLetter {
            out.append(" ")
        } else {
            out.append(char)
            out.append(next)
        }
    }
    return out
}

/// `\x{HEX}`, `\u{HEX}`, `\U{HEX}` (Perl, Ruby, JavaScript, Rust) as the
/// character they name; anything else is kept.
private func decodingBracedEscapes(_ text: String) -> String {
    let chars = Array(text)
    var out = ""
    var index = 0
    while index < chars.count {
        if chars[index] == "\\", index + 2 < chars.count, "xuU".contains(chars[index + 1]), chars[index + 2] == "{",
           let close = chars[(index + 3)..<min(chars.count, index + 12)].firstIndex(of: "}"),
           let value = UInt32(String(chars[(index + 3)..<close]), radix: 16), let scalar = Unicode.Scalar(value)
        {
            out.append(Character(scalar))
            index = close + 1
        } else {
            out.append(chars[index])
            index += 1
        }
    }
    return out
}

/// Runs of letters, digits and `-_./~`: a path stays one token.
private func scriptTokens(_ text: String) -> [String] {
    text.split(whereSeparator: { char in
        (char.isLetter || char.isNumber || "-_./~".contains(char)) == false
    }).map(String.init)
}

/// The last path component is `rv` or `rv-cli`, as a case-insensitive
/// filesystem resolves it (`/usr/local/bin/RV`). A directory named rv
/// (`cd ~/src/rv`) counts too: the text cannot tell them apart.
private func namesRVBinary(_ token: String) -> Bool {
    let last = token.split(separator: "/").last.map { trimmingDots(String($0)) } ?? ""
    return rvProgramNames.contains(last.lowercased())
}

/// Any path component is a weakening word: a sed script or a URL glues
/// words to slashes (`s/.*/rv uninstall/e`).
private func holdsWeakeningWord(_ token: String) -> Bool {
    token.split(separator: "/").contains { scriptWeakeningWords.contains(trimmingDots(String($0))) }
}

private func trimmingDots(_ word: String) -> String {
    String(word.drop(while: { $0 == "." }).reversed().drop(while: { $0 == "." }).reversed())
}

// MARK: - find -exec

private let findNames: Set<String> = ["find", "gfind", "bfs"]
private let findExecPrimaries: Set<String> = ["-exec", "-execdir", "-ok", "-okdir"]

/// The commands `find` runs: the words after each `-exec`, `-execdir`,
/// `-ok` or `-okdir` up to `;` or a `{} +`. The segment splitter is not
/// escape-aware and cuts at `\;`, so a later clause can arrive as its own
/// command headed by the primary (`-exec rv uninstall \`): that is
/// followed too.
func findExecCommands(_ argv: [String]) -> [[String]] {
    guard let program = argv.first else { return [] }
    if findExecPrimaries.contains(unescapeBackslashPairs(program)) {
        return [Array(argv.dropFirst())] + findExecClauses(argv, from: 1)
    }
    guard findNames.contains(program) else { return [] }
    return findExecClauses(argv, from: 1)
}

private func findExecClauses(_ argv: [String], from start: Int) -> [[String]] {
    var commands: [[String]] = []
    var index = start
    while index < argv.count {
        defer { index += 1 }
        guard findExecPrimaries.contains(unescapeBackslashPairs(argv[index])) else { continue }
        var command: [String] = []
        index += 1
        while index < argv.count {
            let word = unescapeBackslashPairs(argv[index])
            if word == ";" || (word == "+" && command.last.map(unescapeBackslashPairs) == "{}") { break }
            command.append(argv[index])
            index += 1
        }
        if command.isEmpty == false { commands.append(command) }
    }
    return commands
}

/// Distinct `find -exec` commands followed per line, and words across the
/// commands they launch; past either, a truncated marker (flagged).
/// Dynamic heads (`find . -exec $F -exec $F …`) would otherwise branch at
/// every word.
private let maxFollowedFindCommands = 256
private let maxFollowedFindWords = 16384

/// `launched` plus every command a `find -exec` among them runs, followed
/// through nested finds, each distinct command once. The resolver's depth
/// cap bounds nesting (past it, a truncated marker, which callers flag).
func followingFindExec(_ launched: [LaunchedCommand]) -> [LaunchedCommand] {
    var out = launched
    var depths = Array(repeating: 0, count: launched.count)
    var followed: Set<[String]> = []
    var words = 0
    var index = 0
    while index < out.count {
        let (command, depth) = (out[index], depths[index])
        index += 1
        for argv in findExecCommands(command.guardArgv) where followed.insert(argv).inserted {
            guard followed.count <= maxFollowedFindCommands else { return out + [.truncatedMarker] }
            let fed = launchedCommandHeads(argv: argv, depth: depth + 1)
            words += fed.reduce(0) { $0 + $1.guardArgv.count }
            guard words <= maxFollowedFindWords else { return out + [.truncatedMarker] }
            out += fed
            depths += Array(repeating: depth + 1, count: fed.count)
        }
    }
    return out
}

// MARK: - stdin programs

/// Python modules that read stdin as data, not as a program. Any other
/// `-m` module (`code`, `asyncio`, `pdb`) may run what stdin says.
private let pythonDataModules: Set<String> = [
    "json.tool", "pip", "pytest", "venv", "http.server", "unittest", "py_compile", "compileall", "timeit",
    "cprofile", "black", "ruff", "mypy", "pydoc", "base64", "gzip", "zipfile", "tarfile", "uuid", "build",
    "twine",
]

/// Whether `launched` may read its program from stdin, whose text the
/// launcher parser never sees. Fail closed: a shell runner always may
/// (`ssh host`, `su user` with no command); a shell, `source`/`.`,
/// interpreter or dynamic head may unless it names a script operand that
/// cannot be an option's value, or carries an inline program (whose
/// reach is `scriptReachesPastItself`). A `-s` cluster or a stdin path
/// operand (`-`, `/dev//stdin`, `/proc/$$/fd/0`, `<(…)`) counts as stdin.
func readsProgramFromStdin(_ launched: LaunchedCommand) -> Bool {
    let argv = launched.guardArgv
    guard let program = argv.first else { return false }
    let isShell = shellNames.contains(program) || program == "source" || program == "."
    if isShellRunner(argv) { return true }
    guard isShell || launched.headIsDynamic || isInterpreter(program) else { return false }
    let operands = argv.dropFirst().map(unescapeBackslashPairs)
    // An inline program reads stdin as data (`scriptReachesPastItself`
    // judges one that runs it); awk's program is an operand, but `-f -`,
    // `-f /dev/fd/3` or `-f $X` may read it from stdin or a descriptor.
    if awkNames.contains(program) {
        return operands.contains(where: isStdinPath)
            || zip(operands, operands.dropFirst()).contains { $0 == "-f" && isUnmodelledOperand($1) }
    }
    if inlineProgram(argv) != nil { return false }
    if operands.contains(where: isStdinPath) { return true }
    if isShell, operands.contains(where: { $0.hasPrefix("-") && $0.hasPrefix("--") == false && $0.contains("s") }) {
        return true
    }
    if let module = pythonModule(program, operands) { return pythonDataModules.contains(module.lowercased()) == false }
    for (index, operand) in operands.enumerated() where isOptionWord(operand) == false {
        // A word after an option may be that option's value (bash alone
        // takes `-o x`, `-init-file x`, `--rcfile x`): keep looking.
        if index > 0, isOptionWord(operands[index - 1]), operands[index - 1].contains("=") == false { continue }
        // The script operand; one that may expand to anything may be stdin.
        return isUnmodelledOperand(operand)
    }
    return true
}

/// `$X`, a backtick or a glob: may expand to any path, stdin included.
private func isUnmodelledOperand(_ word: String) -> Bool {
    word.contains(where: { "$`*?[{".contains($0) })
}

private func isOptionWord(_ word: String) -> Bool {
    word.count > 1 && (word.hasPrefix("-") || word.hasPrefix("+"))
}

/// `-`, any path naming `stdin`, any descriptor path (`/dev/fd/3`,
/// `/proc/$$/fd/0`: a here-string can feed any descriptor), or process
/// substitution.
private func isStdinPath(_ word: String) -> Bool {
    if word == "-" || (word.contains("/") && word.contains("stdin")) || word.hasPrefix("<(") { return true }
    let components = word.split(separator: "/")
    return components.contains("fd") && (components.last?.allSatisfy(\.isNumber) ?? false)
}

/// The module `python -m` runs (attached or the next word); `-W`/`-X`
/// take the rest of their cluster as a value. Nil without `-m`.
private func pythonModule(_ program: String, _ operands: [String]) -> String? {
    guard program.hasPrefix("python") || program.hasPrefix("pypy") else { return nil }
    for (index, word) in operands.enumerated() where word.hasPrefix("-") && word.hasPrefix("--") == false {
        let letters = word.dropFirst().prefix(while: { "WXc".contains($0) == false })
        guard let m = letters.firstIndex(of: "m") else { continue }
        let attached = String(letters[letters.index(after: m)...])
        if attached.isEmpty == false { return attached }
        return index + 1 < operands.count ? operands[index + 1] : ""
    }
    return nil
}

/// `sudo -s`/`-i`/`--shell`/`--login` and `doas -s` start a shell on
/// stdin and launch no command the resolver can see. Judged on the line's
/// words, quoted payloads split too (`sh -c '… | sudo -s'`): a sudo/doas
/// word followed anywhere on the line by such a flag counts. Option values
/// and command boundaries are not modelled (a quoted prompt, `$(whoami)`,
/// `2>&1` or `$'…'` would mislead either): fail closed.
func startsShellOnStdin(_ raw: String) -> Bool {
    let words = raw.split(whereSeparator: { $0.isWhitespace || "'\";&|()<>`".contains($0) })
        .map { unescapeBackslashPairs(String($0)) }
    guard let launcher = words.firstIndex(where: { ["sudo", "doas"].contains(commandName($0)) }) else { return false }
    return words[(launcher + 1)...].contains(where: startsShellFlag)
}

private func startsShellFlag(_ word: String) -> Bool {
    if word.hasPrefix("--") {
        let name = String(word.dropFirst(2).prefix { $0 != "=" })
        return name.isEmpty == false && ("shell".hasPrefix(name) || "login".hasPrefix(name))
    }
    return word.hasPrefix("-") && word.dropFirst().contains(where: { $0 == "s" || $0 == "i" })
}

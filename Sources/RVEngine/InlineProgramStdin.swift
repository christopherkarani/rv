import RVDomain

/// The stdin route into an interpreter: a heredoc, a here-string, an
/// `echo`/`printf` pipe, or an opaque source (`cat file |`, `curl |`,
/// `< file`). Visible programs get the same marker check as inline
/// ones; an opaque program cannot be read at all, so it always needs the
/// judge. An interpreter given a script operand or an inline program
/// reads stdin as data and is not a stdin program.
func stdinProgramRequiresJudge(_ raw: String, secrets: SecretPathCatalog) -> Bool {
    let heredoc = extractHeredoc(raw)
    let header = heredoc?.header ?? raw
    let body = heredoc.flatMap { $0.body.isEmpty ? nil : $0.body }

    for argv in launchedCommands(header) {
        guard let read = stdinRead(argv) else { continue }
        if read.fileRedirect { return true }
        if let text = read.hereString, scriptIsRisky(text, kind: read.kind, secrets: secrets) { return true }
        if read.heredoc, let body, scriptIsRisky(body, kind: read.kind, secrets: secrets) { return true }
    }

    // Any command the consumer segment launches may be the interpreter
    // reading the pipe, and any command the producer segment launches inside
    // a group or payload may write to it (an `eval` or `sh -c` payload
    // launches each view, as written and decoded): `pipeWriters`.
    let pipes = splitTopLevelPipes(header)
    for index in pipes.indices.dropFirst() {
        let reads = launchedCommands(pipes[index]).compactMap(stdinRead).filter {
            $0.hereString == nil && $0.heredoc == false && $0.fileRedirect == false
        }
        let producers = pipeWriters(pipes[index - 1])
        guard reads.isEmpty == false, producers.isEmpty == false else { continue }
        var programs: [String] = []
        for producer in producers {
            guard let program = visibleProgram(from: producer, heredocBody: body) else { return true }
            programs.append(program)
        }
        let texts = programs.count == 1 ? programs : programs + [programs.joined(separator: "\n")]
        let risky = reads.contains { read in
            texts.contains { scriptIsRisky($0, kind: read.kind, secrets: secrets) }
        }
        if risky { return true }
    }
    return false
}

/// The commands of `segment` that may write into the pipe after it. At its
/// top level only the last list element does: what follows its last `;`,
/// `&&`, `||`, `&` or newline (`cd repo && echo … |`). A segment holding a
/// group, subshell, substitution or compound command (`{ a; b; }`, `( … )`,
/// `if …; fi`), which this scan does not parse, is read whole, as is one
/// whose last element launches nothing. The segment's last launched
/// command is always one of them.
private func pipeWriters(_ segment: String) -> [[String]] {
    let all = launchedCommands(segment)
    guard let tail = lastListElement(segment) else { return all }
    var writers = launchedCommands(tail)
    guard writers.isEmpty == false else { return all }
    if let last = all.last, writers.contains(last) == false { writers.append(last) }
    return writers
}

private let compoundWords: Set<String> = [
    "if", "then", "else", "elif", "fi", "while", "until", "do", "done", "for", "in", "case", "esac", "select",
    "function", "coproc", "[[", "]]", "!", "time",
]

/// The text after the last top-level list operator of `segment`, or nil
/// when it holds a group, subshell, substitution, backtick or compound
/// command word outside quotes, or an ANSI-C `$'…'` word. A `&` next to
/// `<` or `>` is a redirect.
private func lastListElement(_ segment: String) -> String? {
    let chars = Array(segment)
    // Each quoted or escaped character masked to `x`.
    var masked = chars
    var quote: Character?
    var index = 0
    while index < chars.count {
        let char = chars[index]
        if char == "\\", quote != "'" {
            masked[index] = "x"
            if index + 1 < chars.count { masked[index + 1] = "x" }
            index += 2
            continue
        }
        if let open = quote {
            masked[index] = "x"
            if char == open { quote = nil }
        } else if char == "'" || char == "\"" {
            masked[index] = "x"
            quote = char
        }
        index += 1
    }
    if masked.contains(where: { "{}()`".contains($0) }) { return nil }
    // In an ANSI-C word `\'` does not close the quote, which this mask
    // assumes it does (`sh -c $'echo \'x\'; y'`).
    if segment.contains("$'") { return nil }
    let words = String(masked).split(whereSeparator: { $0.isWhitespace || ";&|<>".contains($0) })
    if words.contains(where: { compoundWords.contains(String($0)) }) { return nil }
    var start = 0
    for (position, char) in masked.enumerated() {
        let before = position > 0 ? masked[position - 1] : nil
        let after = position + 1 < masked.count ? masked[position + 1] : nil
        switch char {
        case ";", "\n":
            start = position + 1
        case "&" where before != ">" && before != "<" && after != ">":
            start = position + 1
        case "|" where after == "|" || before == "|":
            start = position + 1
        default:
            continue
        }
    }
    let tail = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? nil : tail
}

private struct StdinRead {
    var kind: ProgramKind
    var hereString: String?
    var heredoc = false
    var fileRedirect = false
}

/// The operands that name stdin as a program file: `-` and the paths that
/// open it.
private let stdinOperands: Set<String> = ["-", "/dev/stdin", "/dev/fd/0", "/proc/self/fd/0"]

/// How an interpreter argv takes its program from stdin, or nil when it
/// runs a script file or an inline program instead. The head counts as the
/// program it decodes to (`$'python3'`). Words after `-` or `/dev/stdin`
/// (`stdinOperands`) are the program's arguments, not a script or an inline
/// program (`python3 - -c x`). deno and bun read one only given `-`; awk
/// only from `-f -`; `xargs` running an interpreter with no script operand
/// feeds it the pipe as its program (`xargs python3 -c`).
private func stdinRead(_ written: [String]) -> StdinRead? {
    guard let first = written.first else { return nil }
    let program = commandName(first.ansiCDecodedIfMarked).lowercased()
    var argv = [program] + written.dropFirst()
    if program == "xargs" { return xargsStdinRead(argv) }
    if program == "osascript" { return osascriptStdinRead(argv) }
    if awkNames.contains(program) { return awkStdinRead(argv) }
    let explicitOnly = program == "deno" || program == "bun"
    if explicitOnly, argv.count > 1, argv[1] == "run" { argv.remove(at: 1) }
    let options = argv.prefix { stdinOperands.contains($0) == false }
    guard let kind = explicitOnly ? ProgramKind.plain : stdinProgramKind(program), inlineProgram(Array(options)) == nil
    else { return nil }
    var read = StdinRead(kind: kind)
    var sawStdin = false
    var index = 1
    while index < argv.count {
        let arg = argv[index]
        index += 1
        if scanStdinRedirect(argv, at: &index, into: &read) {
            continue
        } else if stdinOperands.contains(arg) {
            sawStdin = true
        } else if sawStdin || arg.contains(">") {
            continue
        } else if arg.hasPrefix("-") {
            // An option's separate value (`python3 -W ignore`, `node -r
            // dotenv/config`, `ruby -r json`) is no script, and never a
            // redirect (`python3 -W <<< …`). A value naming stdin (`node -r
            // /dev/stdin app.js`, `ruby -r - main.rb`) is not skipped: the
            // interpreter may load it as code, so it counts as the stdin
            // operand on the next word (fail closed).
            if separateValueOptions(program).contains(arg), index < argv.count,
               argv[index].hasPrefix("<") == false, argv[index].hasPrefix(">") == false,
               stdinOperands.contains(argv[index]) == false
            {
                index += 1
            }
        } else {
            return nil
        }
    }
    if explicitOnly, sawStdin == false, read.hereString == nil, read.heredoc == false, read.fileRedirect == false {
        return nil
    }
    return read
}

/// Records the stdin redirect `argv[index - 1]` opens (a here-string,
/// heredoc or `<` file; not `<(…)`) into `read`, stepping `index` past its
/// target word, or false when it is no stdin redirect.
private func scanStdinRedirect(_ argv: [String], at index: inout Int, into read: inout StdinRead) -> Bool {
    let arg = argv[index - 1]
    if arg == "<<<" {
        read.hereString = index < argv.count ? argv[index] : ""
        index += 1
    } else if arg.hasPrefix("<<<") {
        read.hereString = String(arg.dropFirst(3))
    } else if arg == "<<" || arg == "<<-" {
        read.heredoc = true
        index += 1
    } else if arg.hasPrefix("<<") {
        read.heredoc = true
    } else if arg == "<" {
        read.fileRedirect = true
        index += 1
    } else if arg.hasPrefix("<"), arg.hasPrefix("<(") == false {
        read.fileRedirect = true
    } else {
        return false
    }
    return true
}

/// awk reading its program from stdin (`-f -`, `--file=/dev/stdin`,
/// `-f/dev/fd/0`), with the redirect that feeds it, or nil.
private func awkStdinRead(_ argv: [String]) -> StdinRead? {
    let readsStdin = argv.indices.dropFirst().contains { index in
        let arg = argv[index]
        for prefix in ["--file=", "-f"] where arg.hasPrefix(prefix) && arg.count > prefix.count {
            if stdinOperands.contains(String(arg.dropFirst(prefix.count))) { return true }
        }
        return (arg == "-f" || arg == "--file") && index + 1 < argv.count && stdinOperands.contains(argv[index + 1])
    }
    guard readsStdin else { return nil }
    var read = StdinRead(kind: .awk)
    var index = 1
    while index < argv.count {
        index += 1
        _ = scanStdinRedirect(argv, at: &index, into: &read)
    }
    return read
}

/// `xargs` running an interpreter given no script operand after it (only
/// options and `{}`): the words it reads from the pipe reach the
/// interpreter as its program or the inline program's text.
private func xargsStdinRead(_ argv: [String]) -> StdinRead? {
    for index in argv.indices.dropFirst() {
        let name = commandName(argv[index].ansiCDecodedIfMarked).lowercased()
        let kind: ProgramKind? = awkNames.contains(name) ? .awk
            : (name == "deno" || name == "bun") ? .plain : stdinProgramKind(name)
        guard let kind else { continue }
        let rest = argv[(index + 1)...].filter { ($0 == "run" && (name == "deno" || name == "bun")) == false }
        let scriptless = rest.allSatisfy { $0.hasPrefix("-") || $0.contains("{}") }
        return scriptless ? StdinRead(kind: kind) : nil
    }
    return nil
}

/// `osascript` with no script file, or `-` (`stdinOperands`), and no `-e`
/// before it: it runs stdin, and words after `-` are the script's
/// arguments.
private func osascriptStdinRead(_ argv: [String]) -> StdinRead? {
    var sawStdin = false
    var index = 1
    while index < argv.count {
        let arg = argv[index]
        index += 1
        // Any input redirect is read as an opaque program.
        if arg.hasPrefix("<") {
            var read = StdinRead(kind: .appleScript)
            read.fileRedirect = true
            return read
        }
        if stdinOperands.contains(arg) {
            sawStdin = true
        } else if sawStdin {
            continue
        } else if arg == "-e" {
            return nil
        } else if arg == "-l" || arg == "-s" || arg == ">" || arg == ">>" {
            index += 1
        } else if arg.contains(">") {
            continue
        } else if arg.hasPrefix("-") == false {
            return nil
        }
    }
    return StdinRead(kind: .appleScript)
}

/// The options of `program` that take their value as the next word, which
/// is then no script operand.
private func separateValueOptions(_ program: String) -> Set<String> {
    if isPythonExecutable(program) { return ["-W", "-X", "--check-hash-based-pycs"] }
    if isNodeExecutable(program) {
        return [
            "-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
            "--input-type", "--title", "--env-file", "--env-file-if-exists", "--inspect-port", "--disable-warning",
        ]
    }
    if isRubyExecutable(program) { return ["-r", "-I", "-C", "-E", "--encoding"] }
    if isLuaExecutable(program) { return ["-l"] }
    if isPHPExecutable(program) { return ["-d", "-c", "-z"] }
    if isPerlExecutable(program) { return ["-I"] }
    return []
}

private func stdinProgramKind(_ program: String) -> ProgramKind? {
    if isPythonExecutable(program) || isNodeExecutable(program) || isLuaExecutable(program) {
        return .plain
    }
    if isPerlExecutable(program) || isRubyExecutable(program) || isPHPExecutable(program) {
        return .shellQuoting
    }
    return nil
}

/// Program text a producer pipes in: `echo`/`printf` operands, or a
/// heredoc body fed through `cat <<EOF`. Nil when the source is opaque.
private func visibleProgram(from producer: [String], heredocBody: String?) -> String? {
    guard let program = producer.first else { return nil }
    if program == "echo" || program == "printf" {
        return producer.dropFirst().joined(separator: " ")
    }
    if program == "cat", let heredocBody, producer.dropFirst().contains(where: { $0.hasPrefix("<<") }) {
        return heredocBody
    }
    return nil
}

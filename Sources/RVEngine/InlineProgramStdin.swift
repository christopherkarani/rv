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

    // No launched command is picked by position: any command the consumer
    // segment launches may be the interpreter reading the pipe, and any
    // command the producer segment launches may write to it (an `eval` or
    // `sh -c` payload launches each view, as written and decoded, and a
    // group or payload may run several commands).
    let pipes = splitTopLevelPipes(header)
    for index in pipes.indices.dropFirst() {
        let reads = launchedCommands(pipes[index]).compactMap(stdinRead).filter {
            $0.hereString == nil && $0.heredoc == false && $0.fileRedirect == false
        }
        let producers = launchedCommands(pipes[index - 1])
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

private struct StdinRead {
    var kind: ProgramKind
    var hereString: String?
    var heredoc = false
    var fileRedirect = false
}

/// How an interpreter argv takes its program from stdin, or nil when it
/// runs a script file or an inline program instead.
private func stdinRead(_ argv: [String]) -> StdinRead? {
    guard let program = argv.first?.lowercased(), let kind = stdinProgramKind(program),
          inlineProgram(argv) == nil
    else { return nil }
    var read = StdinRead(kind: kind)
    var index = 1
    while index < argv.count {
        let arg = argv[index]
        index += 1
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
        } else if arg == "-" || arg == "/dev/stdin" || arg.hasPrefix("-") || arg.contains(">") {
            continue
        } else {
            return nil
        }
    }
    return read
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

import RVDomain

/// Observe floor: true when part of `command` that rv cannot read can
/// occupy a command position, so the line may run any program at all.
///
/// Floored: a dynamic command word (`$x`, `$(…)`, backticks, `<(…)`);
/// `eval` of dynamic text; `source`/`.` of stdin, a descriptor or a
/// process substitution; a shell or interpreter running a dynamic script
/// operand, a process substitution, a dynamic here-string or heredoc, or
/// dynamic or encoded inline code; a shell or interpreter reading its
/// program from stdin unless every producer is a literal `echo`/`printf`,
/// a `cat` of literal paths or a literal heredoc, and then the program
/// text it is fed is scanned like the line (and read by the stop floor);
/// inline code that runs a command over input rv cannot read; `awk`
/// running a command; `sed` with `e`; `ssh` with a dynamic remote
/// command; a dynamic `trap` action; `xargs`, `find -exec` and `parallel`
/// whose verb is a shell, an interpreter, `eval`, `source`, `env -S`,
/// dynamic, or a process or service control verb (`kill`, `launchctl`,
/// `rv`, …), and `parallel` with no verb, which runs its input; a function
/// or alias that redefines a name the floor reads (`echo(){ …; }`),
/// `coproc`, `>&p` and `hash -p`; text the shells may split differently
/// (an unbalanced group, a `}` argument); and a command too large to walk
/// within budget. Command names are matched unescaped, case-folded and by
/// basename (`\sh`, `/BIN/SH`). Not floored: a literal verb with dynamic
/// arguments (`xargs rm`), and a literal script file (`bash x.sh`, `cat
/// x.sh | sh`), whose contents rv does not read.
package func runsOpaqueProgram(_ command: ShellCommand) -> Bool {
    scanOpaqueProgram(command).opaque
}

enum OpaqueExecution {
    // MARK: Segments

    /// The command's words, its heredoc, its stdin, the scan depth.
    struct Context {
        let segment: [CommandToken]
        let heredoc: ShellLexer.Heredoc?
        let feed: () -> Feed
        let depth: Int

        /// The same stdin for a nested command text (`eval`, `-c`).
        var stdin: () -> Feed {
            let segment = segment
            let heredoc = heredoc
            let feed = feed
            return { OpaqueExecution.stdin(segment, heredoc: heredoc, feed: feed) }
        }
    }

    static func segmentRunsOpaque(_ context: Context, state: inout ScanState) -> Bool {
        switch commandStart(context.segment) {
        case .none:
            return false
        case .opaque:
            return true
        case .at(let index):
            return commandRunsOpaque(Array(context.segment[index...]), context, state: &state)
        }
    }

    private static func commandRunsOpaque(_ tokens: [CommandToken], _ context: Context, state: inout ScanState) -> Bool {
        guard let headToken = tokens.first else { return false }
        if isDynamic(headToken) { return true }
        let head = commandName(headToken.decoded)
        let arguments = Array(tokens.dropFirst())
        let depth = context.depth
        if state.definedNames.contains(head) {
            // A function or alias runs what its body does with this stdin.
            return context.stdin().literal == false
        }
        if head == "eval" {
            if arguments.contains(where: isDynamic) { return true }
            return scan(arguments.map(\.decoded).joined(separator: " "), depth: depth + 1, inherited: context.stdin, state: &state)
        }
        if head == "source" || head == "." {
            return sourcesOpaque(arguments)
        }
        if shells.contains(head) {
            return shellRunsOpaque(arguments, context, state: &state)
        }
        if isInterpreter(head) {
            return interpreterRunsOpaque(head, arguments, context, state: &state)
        }
        switch head {
        case "awk", "gawk", "mawk", "nawk":
            return awkRunsOpaque(arguments)
        case "sed", "gsed":
            return sedRunsOpaque(arguments)
        case "ssh":
            return sshRunsOpaque(arguments, depth: depth, inherited: context.stdin, state: &state)
        case "trap":
            return trapRunsOpaque(arguments, depth: depth, state: &state)
        case "xargs":
            return optionReadings(arguments, valueOptions: xargsValueOptions, flags: xargsFlags, separators: []).contains(where: verbRunsOpaque)
        case "parallel":
            let readings = optionReadings(
                arguments, valueOptions: parallelValueOptions, flags: parallelFlags, separators: parallelSeparators
            )
            return readings.isEmpty || readings.contains(where: verbRunsOpaque)
        case "find":
            return findExecVerbs(arguments).contains(where: verbRunsOpaque)
        default:
            return false
        }
    }

    // MARK: Command position

    enum Start {
        case none
        case opaque
        case at(Int)
    }

    /// Index of the command word after assignments, redirects, reserved
    /// words, case patterns and transparent wrappers. `.opaque` when a
    /// wrapper splits a string into a command (`env -S`) or a word in
    /// wrapper position is dynamic.
    static func commandStart(_ tokens: [CommandToken]) -> Start {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let word = token.decoded
            if ShellLexer.isRedirectOperator(token) {
                index += 2
                continue
            }
            if token.wasQuoted == false {
                if isAssignment(word) || skippedWords.contains(word) || isCasePattern(word) {
                    index += 1
                    continue
                }
                if word == "case" {
                    guard let found = tokens.dropFirst(index + 1).firstIndex(where: { $0.decoded == "in" }) else { return .none }
                    index = found + 1
                    continue
                }
                if notCommands.contains(word) { return .none }
            }
            let name = commandName(word)
            guard let options = wrapperValueOptions[name] else { return .at(index) }
            if name == "command",
               tokens.dropFirst(index + 1).first.map({ $0.decoded == "-v" || $0.decoded == "-V" }) == true
            {
                // `command -v`: prints, runs nothing.
                return .at(index)
            }
            index += 1
            // The wrapper's options, then its operand slots.
            while index < tokens.count {
                let option = tokens[index]
                if isDynamic(option) { return .opaque }
                let text = option.decoded
                if name == "env", text == "-S" || text.hasPrefix("-S") || text.hasPrefix("--split-string") {
                    return .opaque
                }
                if text == "--" { index += 1; break }
                guard text.hasPrefix("-"), text.count > 1 else { break }
                index += options.contains(text) ? 2 : 1
            }
            if name == "timeout" || name == "repeat", index < tokens.count { index += 1 }
            if name == "env" {
                while index < tokens.count, tokens[index].wasQuoted == false, isAssignment(tokens[index].decoded) {
                    index += 1
                }
            }
        }
        return .none
    }

    /// `a)`, `(a|b)`: a case arm's pattern.
    private static func isCasePattern(_ word: String) -> Bool {
        word.hasSuffix(")") && (word.contains("(") == false || word.hasPrefix("("))
    }

    /// Wrappers that run their operand, and the options that take a value.
    static let wrapperValueOptions: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-U", "-D", "-r", "-t", "-T"],
        "doas": ["-u", "-C"],
        "env": ["-u", "-C", "-P", "--unset", "--chdir"],
        "command": [], "builtin": [], "exec": ["-a"], "nohup": [], "time": [],
        "nice": ["-n", "--adjustment"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"],
        "stdbuf": ["-i", "-o", "-e"],
        "setsid": [], "caffeinate": ["-t", "-w"],
        "arch": ["-arch", "-d", "-e"],
        "xcrun": ["--sdk", "-sdk", "--toolchain", "-toolchain"],
        "noglob": [], "nocorrect": [], "repeat": [],
    ]

    private static let skippedWords: Set<String> = [
        "!", "{", "(", "if", "then", "else", "elif", "do", "while", "until",
    ]

    /// Heads that start no command: loop headers, closers.
    private static let notCommands: Set<String> = [
        "for", "done", "fi", "esac", "}", ")", "function", "in",
    ]

    // MARK: Runners

    private static func sourcesOpaque(_ arguments: [CommandToken]) -> Bool {
        let operands = droppingRedirects(arguments)
        guard let operand = operands.first(where: { $0.decoded.hasPrefix("-") == false || $0.decoded == "-" }) else {
            return arguments.contains(where: isDynamic)
        }
        return isDynamic(operand) || readsStdin(operand.decoded)
    }

    private static func shellRunsOpaque(_ rawArguments: [CommandToken], _ context: Context, state: inout ScanState) -> Bool {
        if feedsOpaqueInput(rawArguments) { return true }
        let arguments = droppingRedirects(rawArguments)
        var index = 0
        var command = false
        var stdin = false
        while index < arguments.count {
            let text = arguments[index].decoded
            if text == "--" { index += 1; break }
            guard text.hasPrefix("-") || text.hasPrefix("+"), text.count > 1, arguments[index].wasQuoted == false else {
                break
            }
            if text == "-o" || text == "+o" || text == "-O" || text == "+O" { index += 2; continue }
            // fish: `--command`/`-C`/`--init-command` take the script.
            if text == "--command" || text == "--init-command" || text == "-C" {
                command = true
                index += 1
                break
            }
            if text.hasPrefix("--command=") || text.hasPrefix("--init-command=") {
                let payload = CommandToken(decoded: String(text.drop(while: { $0 != "=" }).dropFirst()), wasQuoted: true)
                return payloadRunsOpaque(payload, context, state: &state)
            }
            if text.hasPrefix("--") == false {
                if text.contains("c") { command = true }
                if text.contains("s") { stdin = true }
            }
            index += 1
        }
        if command {
            guard index < arguments.count else { return false }
            return payloadRunsOpaque(arguments[index], context, state: &state)
        }
        let operand = index < arguments.count && stdin == false ? arguments[index] : nil
        guard let operand, operand.decoded != "-", readsStdin(operand.decoded) == false else {
            // The program is stdin: readable only when fed literal text,
            // which is then read like the line itself.
            let fed = context.stdin()
            guard fed.literal else { return true }
            return fed.texts.contains { literalProgramRunsOpaque($0, context, state: &state) }
        }
        return isDynamic(operand)
    }

    /// Program text a shell reads from a literal pipe, here-string or
    /// heredoc: the stop floor reads it, then it is scanned with the same
    /// text as its stdin (a nested `sh` reads the rest of it).
    private static func literalProgramRunsOpaque(_ text: String, _ context: Context, state: inout ScanState) -> Bool {
        guard text.isEmpty == false else { return false }
        guard state.charge(work: text.utf8.count) else { return true }
        if state.record(text), RVDStopGuard.stopsRVD(text) { return true }
        return scan(text, depth: context.depth + 1, inherited: { Feed(literal: true, text: text) }, state: &state)
    }

    /// A shell's `-c` script: dynamic or escaped text is unreadable; a
    /// literal one is scanned, inheriting the shell's stdin.
    private static func payloadRunsOpaque(_ payload: CommandToken, _ context: Context, state: inout ScanState) -> Bool {
        if payload.wasAnsiC { return true }
        if payload.wasQuoted == false, isDynamic(payload) { return true }
        if splitSegments(payload.decoded).contains(where: { decodes(ShellLexer.words($0)) }) { return true }
        return scan(payload.decoded, depth: context.depth + 1, inherited: context.stdin, state: &state)
    }

    private static func interpreterRunsOpaque(
        _ head: String, _ rawArguments: [CommandToken], _ context: Context, state: inout ScanState
    ) -> Bool {
        if feedsOpaqueInput(rawArguments) { return true }
        let arguments = droppingRedirects(rawArguments)
        let inline = inlineFlags(head)
        var payloads: [CommandToken] = []
        var operand: CommandToken?
        var loopsOverInput = false
        var index = 0
        if head == "deno", arguments.first?.decoded == "eval" {
            payloads = Array(arguments.dropFirst().prefix(1))
            index = arguments.count
        }
        while index < arguments.count {
            let token = arguments[index]
            let text = head == "pwsh" ? token.decoded.lowercased() : token.decoded
            if text == "--" {
                operand = arguments.dropFirst(index + 1).first
                break
            }
            if (head == "perl" || head == "ruby"), text.hasPrefix("-"), text.hasPrefix("--") == false,
               text.contains("n") || text.contains("p")
            {
                // `-n`/`-p` run the code once per input line.
                loopsOverInput = true
            }
            if inline.contains(text) || isClusteredInline(head, text) {
                if index + 1 < arguments.count { payloads.append(arguments[index + 1]) }
                index += 2
                continue
            }
            if text == "-m", index + 1 < arguments.count {
                // `python -m <module>`: the module is the program.
                operand = arguments[index + 1]
                break
            }
            if text.hasPrefix("-"), text.count > 1 {
                index += 1
                continue
            }
            operand = token
            break
        }
        if payloads.isEmpty == false {
            return payloads.contains { payload in
                if codeStopsRVD(payload.decoded, state: &state) { return true }
                if payload.wasAnsiC || carriesSubstitution(payload.decoded) || payload.decoded.hasPrefix("$")
                    || (payload.wasQuoted == false && payload.decoded.contains("$"))
                {
                    return true
                }
                guard execsCode(payload.decoded) else { return false }
                // Code that runs a command over text rv cannot read: its
                // own decode or input, stdin from an unreadable producer,
                // or a dynamic argument or environment word it is handed.
                return readsUnseen(payload.decoded) || loopsOverInput
                    || context.stdin().literal == false
                    || context.segment.contains { isDynamic($0) && $0.decoded != payload.decoded }
            }
        }
        guard let operand, operand.decoded != "-", readsStdin(operand.decoded) == false else {
            // The program is stdin: unreadable unless fed literal text;
            // then it is judged like inline code, and the stop floor reads it.
            let fed = context.stdin()
            guard fed.literal else { return true }
            return fed.texts.contains { program in
                guard program.isEmpty == false else { return false }
                // Every reader of the text is charged for it, so thousands
                // of readers of one big feed run out of budget.
                guard state.charge(work: program.utf8.count) else { return true }
                if state.record(program), RVDStopGuard.stopsRVD(program) { return true }
                // Code read before was clean then, and is the same text now.
                guard state.firstCodeRead(program) else { return false }
                return codeStopsRVD(program, state: &state) || execsCode(program) && readsUnseen(program)
            }
        }
        return isDynamic(operand)
    }

    /// The string literals of inline code (`os.system("launchctl …")`):
    /// each may be a command it runs, so the stop floor reads each.
    private static func codeStopsRVD(_ code: String, state: inout ScanState) -> Bool {
        let fresh = quotedStrings(code).filter { state.record($0) }
        return fresh.contains { RVDStopGuard.stopsRVD($0) }
    }

    private static func quotedStrings(_ code: String) -> [String] {
        var strings: [String] = []
        var quote: Unicode.Scalar?
        var current = String.UnicodeScalarView()
        var escaped = false
        for scalar in code.unicodeScalars {
            guard let open = quote else {
                if scalar == "'" || scalar == "\"" || scalar == "`" { quote = scalar }
                continue
            }
            if escaped {
                current.append(scalar)
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else if scalar == open {
                if current.isEmpty == false { strings.append(String(current)) }
                current = String.UnicodeScalarView()
                quote = nil
            } else {
                current.append(scalar)
            }
        }
        return strings
    }

    /// A here-string with dynamic or ANSI-C content, or a process
    /// substitution as an operand: what the program reads is unseen.
    private static func feedsOpaqueInput(_ arguments: [CommandToken]) -> Bool {
        for (index, token) in arguments.enumerated() {
            if token.wasQuoted == false, isProcessSubstitution(token.decoded) { return true }
            guard ShellLexer.isRedirectOperator(token), redirectOperator(token.decoded) == "<<<" else { continue }
            guard let content = arguments.dropFirst(index + 1).first else { return true }
            if content.wasAnsiC || isDynamic(content) { return true }
        }
        return false
    }

    /// The arguments without redirects and their targets (`2>/dev/null`,
    /// `< in`, `<<EOF`), so a redirect is never read as an operand.
    static func droppingRedirects(_ arguments: [CommandToken]) -> [CommandToken] {
        var kept: [CommandToken] = []
        var index = 0
        while index < arguments.count {
            if ShellLexer.isRedirectOperator(arguments[index]) {
                index += 2
                continue
            }
            kept.append(arguments[index])
            index += 1
        }
        return kept
    }

    /// The verb a runner (`xargs`, `parallel`) runs, after its options:
    /// one reading per way an unknown option could be read (with or
    /// without a value), so an option the table lacks cannot hide the
    /// verb. Empty when a separator (`:::`) comes first: no verb.
    private static func optionReadings(
        _ rawArguments: [CommandToken], valueOptions: Set<String>, flags: Set<String>, separators: Set<String>
    ) -> [[CommandToken]] {
        let arguments = droppingRedirects(rawArguments)
        var index = 0
        var sawUnknown = false
        while index < arguments.count {
            let text = arguments[index].decoded
            if separators.contains(text) { break }
            if text == "--" { index += 1; break }
            guard text.hasPrefix("-"), text.count > 1 else { break }
            let takesValue = valueOptions.contains(text)
            let glued = text.contains("=") || (text.hasPrefix("--") == false && text.count > 2)
            if takesValue == false, glued == false, flags.contains(text) == false { sawUnknown = true }
            index += takesValue ? 2 : 1
        }
        let starts = sawUnknown ? [index, index + 1] : [index]
        return starts.compactMap { start in
            let verb = arguments.dropFirst(start).prefix { separators.contains($0.decoded) == false }
            return verb.isEmpty ? nil : Array(verb)
        }
    }

    private static let xargsValueOptions: Set<String> = [
        "-I", "-i", "-L", "-l", "-n", "-P", "-s", "-d", "-E", "-e", "-a", "-J", "-R", "-S",
        "--delimiter", "--arg-file", "--max-args", "--max-procs", "--max-lines", "--replace", "--eof",
        "--max-chars", "--process-slot-var",
    ]

    private static let xargsFlags: Set<String> = [
        "-0", "-r", "-t", "-p", "-x", "-o", "--null", "--no-run-if-empty", "--verbose", "--interactive",
        "--exit", "--open-tty", "--show-limits",
    ]

    private static let parallelFlags: Set<String> = [
        "-0", "-k", "-q", "-v", "-u", "-r", "-m", "-X", "-g", "--null", "--keep-order", "--quote", "--verbose",
        "--dry-run", "--dryrun", "--ungroup", "--line-buffer", "--lb", "--group", "--tag", "--bar", "--progress",
        "--eta", "--xargs", "--pipe", "--spreadstdin", "--pipepart", "--no-notice", "--will-cite", "--plus",
        "--nonall", "--onall", "--shuf", "--gnu", "--no-run-if-empty", "--files", "--resume", "--resume-failed",
        "--retry-failed", "--fg", "--bg", "--semaphore", "--linebuffer", "--keeporder",
    ]

    private static let parallelSeparators: Set<String> = [":::", "::::", ":::+", "::::+"]

    /// GNU parallel's options that take a separate value.
    private static let parallelValueOptions: Set<String> = [
        "-a", "--arg-file", "--arg-file-sep", "--arg-sep", "--basefile", "--bf", "--block", "--block-size",
        "--blocktimeout", "--bt", "-C", "--colsep", "--compress-program", "--decompress-program", "-d",
        "--delimiter", "--delay", "-E", "--eof", "--env", "--halt", "--halt-on-error", "--header", "-I",
        "--replace", "-j", "--jobs", "-P", "--max-procs", "--joblog", "--jl", "-J", "--profile", "-L",
        "--max-lines", "--limit", "--load", "--memfree", "--memsuspend", "-n", "--max-args", "-N", "--nice",
        "--results", "--res", "--retries", "--return", "--rpl", "-s", "--max-chars", "--sshdelay", "-S",
        "--sshlogin", "--slf", "--sshloginfile", "--tag-string", "--tagstring", "--tmpdir", "--tempdir",
        "--tf", "--transferfile", "--wd", "--workdir", "--termseq", "--template", "--timeout", "--sql",
        "--sqlmaster", "--sqlworker", "--sqlandworker", "--seqreplace", "--ssh",
    ]

    /// The commands after each `-exec`/`-execdir`/`-ok`/`-okdir`.
    private static func findExecVerbs(_ arguments: [CommandToken]) -> [[CommandToken]] {
        arguments.indices.compactMap { index in
            ["-exec", "-execdir", "-ok", "-okdir"].contains(arguments[index].decoded)
                ? Array(arguments.dropFirst(index + 1)) : nil
        }
    }

    /// A runner's verb: a shell, an interpreter, `eval`, `source`, a
    /// dynamic word, or a placeholder (`{}`) takes its program from data.
    /// A process or service control verb (`xargs launchctl`, `parallel
    /// kill ::: …`) is fed its operands from input rv cannot read, so it
    /// may stop rvd whatever the input's source.
    private static func verbRunsOpaque(_ verb: [CommandToken]) -> Bool {
        switch commandStart(verb) {
        case .none:
            return false
        case .opaque:
            return true
        case .at(let index):
            let token = verb[index]
            if isDynamic(token) || token.decoded.contains("{}") || token.decoded == "%" { return true }
            let head = commandName(token.decoded)
            let arguments = Array(verb.dropFirst(index + 1))
            switch head {
            case "awk", "gawk", "mawk", "nawk":
                return awkRunsOpaque(arguments)
            case "sed", "gsed":
                return sedRunsOpaque(arguments)
            default:
                // `ssh`: the input words join its remote command.
                return shells.contains(head) || isInterpreter(head) || lifecycleVerbs.contains(head)
                    || ["eval", "source", ".", "xargs", "parallel", "find", "ssh"].contains(head)
            }
        }
    }

    static let lifecycleVerbs: Set<String> = ["kill", "pkill", "killall", "launchctl", "rv", "rvd", "systemctl"]

    // MARK: Decoders

    /// The segment turns unreadable bytes into text: a decoder, an escape
    /// expansion, or a fetch. An extra signal for `-c` scripts only; it
    /// never decides that a command is readable.
    private static func decodes(_ tokens: [CommandToken]) -> Bool {
        if tokens.contains(where: { $0.wasAnsiC && $0.decoded.contains("\\") }) { return true }
        guard case .at(let index) = commandStart(tokens) else { return false }
        let head = commandName(tokens[index].decoded)
        let arguments = tokens.dropFirst(index + 1).map(\.decoded)
        let flags = arguments.filter { $0.hasPrefix("-") }
        func hasShortFlag(_ letters: Set<Character>) -> Bool {
            flags.contains { $0.hasPrefix("--") == false && $0.dropFirst().contains(where: letters.contains) }
        }
        switch head {
        case "openssl", "rev", "tr", "uudecode", "b64decode", "gunzip", "zcat", "bzcat", "xzcat", "unxz", "bunzip2",
             "zstdcat", "unzstd", "curl", "wget":
            return true
        case "base64", "gbase64", "basenc", "base32", "gbase32":
            return hasShortFlag(["d", "D"]) || flags.contains { $0.hasPrefix("--d") }
        case "xxd":
            return hasShortFlag(["r"])
        case "gzip", "bzip2", "xz", "zstd":
            return hasShortFlag(["d"]) || flags.contains { $0.hasPrefix("--dec") }
        case "printf":
            return arguments.contains(where: hasEscapes)
        case "echo":
            return hasShortFlag(["e"]) && arguments.contains { $0.contains("\\") }
        default:
            return false
        }
    }

    private static func hasEscapes(_ text: String) -> Bool {
        if text.contains("%b") { return true }
        let scalars = Array(text.unicodeScalars)
        for index in scalars.indices.dropLast() where scalars[index] == "\\" {
            let next = scalars[index + 1]
            if next == "x" || next == "u" || next == "U" || ("0"..."7").contains(next) { return true }
        }
        return false
    }

    /// Inline code that runs a command or code it builds.
    private static func execsCode(_ code: String) -> Bool {
        execMarkers.contains { code.contains($0) }
    }

    /// Inline code that reads text rv cannot see: it decodes bytes, or
    /// reads stdin, arguments, the environment, a file or the network.
    private static func readsUnseen(_ code: String) -> Bool {
        decodeMarkers.contains { code.contains($0) } || inputMarkers.contains { code.contains($0) }
    }

    private static let execMarkers = [
        "system(", "system ", "exec(", "exec ", "eval(", "popen", "spawn", "subprocess", "execSync", "child_process",
        "do shell script", "shell_exec", "passthru", "proc_open", "os.execute", "io.popen", "`",
        "execv", "Process(", "Kernel.", "IO.popen", "compile(", "__import__",
    ]

    private static let decodeMarkers = [
        "b64decode", "base64", "decodebytes", "a85decode", "b32decode", "fromhex", "unhexlify",
        "codecs", "zlib", "Buffer.from", "atob", "pack(", "decode_base64", "chr(", "fromCharCode",
        "rot13", "[::-1]", "reverse", "gzinflate", "hex2bin", "\\x",
    ]

    private static let inputMarkers = [
        "stdin", "STDIN", "argv", "ARGV", "ARGF", "ENV", "environ", "getenv", "process.env", "readline",
        "input(", "open(", "gets", "read(", "<>", "$_", "urlopen", "urllib", "requests", "fetch(", "http",
        "socket", "Net::", "LWP",
    ]

    // MARK: Words

    static let shells: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "ksh93", "mksh", "rbash", "fish", "ash", "yash", "csh", "tcsh",
        "nu", "xonsh",
    ]

    /// `head` is already case-folded.
    static func isInterpreter(_ head: String) -> Bool {
        head.hasPrefix("python") || head.hasPrefix("pypy")
            || ["node", "nodejs", "bun", "deno", "ruby", "perl", "php", "lua", "luajit", "osascript", "rscript", "tclsh", "pwsh"]
            .contains(head)
    }

    private static func inlineFlags(_ head: String) -> Set<String> {
        if head.hasPrefix("python") || head.hasPrefix("pypy") { return ["-c"] }
        switch head {
        case "node", "nodejs", "bun": return ["-e", "-p", "--eval", "--print"]
        case "php": return ["-r"]
        case "perl": return ["-e", "-E"]
        case "rscript": return ["-e"]
        case "pwsh": return ["-c", "-command", "-encodedcommand", "-e", "-ec"]
        default: return ["-e"]
        }
    }

    /// `perl -lne 'code'`, `ruby -ne 'code'`: a short cluster ending in the
    /// inline flag.
    private static func isClusteredInline(_ head: String, _ text: String) -> Bool {
        guard head == "perl" || head == "ruby", text.hasPrefix("-"), text.hasPrefix("--") == false else {
            return false
        }
        return text.count > 2 && (text.hasSuffix("e") || text.hasSuffix("E"))
    }

    /// Text rv cannot read: an expansion, a substitution, or a process
    /// substitution (`<(…)`, `>(…)`, zsh `=(…)`).
    static func isDynamic(_ token: CommandToken) -> Bool {
        token.decoded.contains("$") || token.decoded.contains("`")
            || token.wasQuoted == false && isProcessSubstitution(token.decoded)
    }

    static func isProcessSubstitution(_ word: String) -> Bool {
        word.hasPrefix("<(") || word.hasPrefix(">(") || word.hasPrefix("=(")
    }

    static func readsStdin(_ path: String) -> Bool {
        path == "-" || path == "/dev/stdin" || path.hasPrefix("/dev/fd/") || path.hasPrefix("/proc/self/fd/")
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, assignmentNameStart.contains(first) else { return false }
        return name.allSatisfy { assignmentNameChars.contains($0) || $0 == "+" && name.last == "+" }
    }
}

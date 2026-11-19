import RVDomain

/// Observe floor: true when part of `command` that rv cannot read can
/// occupy a command position, so the line may run any program at all.
///
/// Floored: a dynamic command word (`$x`, `$(…)`, backticks); `eval` of
/// dynamic text; `source`/`.` of stdin, a descriptor or `<(…)`; a shell or
/// interpreter running a dynamic script operand, `<(…)`, a dynamic
/// here-string or dynamic or encoded inline code; a shell or interpreter
/// reading its program from stdin unless every producer is a literal
/// `echo`/`printf` or a `cat` of literal paths (`StdinFeed`); inline code
/// that runs a command over input rv cannot read; `awk` running a command;
/// `sed` with `e`; `ssh` with a dynamic remote command; a dynamic `trap`
/// action; `xargs`, `find -exec` and `parallel` whose verb is a shell, an
/// interpreter, `eval`, `source`, `env -S`, dynamic, or a process or
/// service control verb (`kill`, `launchctl`, `rv`, …), and `parallel`
/// with no verb, which runs its input. Line continuations are joined
/// first. Not floored: a literal verb with dynamic arguments (`xargs rm`),
/// and a literal script file (`bash x.sh`, `cat x.sh | sh`), whose
/// contents rv does not read.
package func runsOpaqueProgram(_ command: ShellCommand) -> Bool {
    OpaqueExecution.scan(command.rawValue, depth: 0)
}

enum OpaqueExecution {
    private static let maxDepth = 4

    /// `inheritedLiteral`: whether the stdin the text starts with (an
    /// enclosing `sh -c`'s, say) is readable.
    static func scan(_ text: String, depth: Int, inheritedLiteral: Bool = true) -> Bool {
        guard depth <= maxDepth else { return true }
        let line = joiningContinuations(text)
        let inherited = inheritedLiteral && redirectsLineStdin(line) == false
        for element in listElements(line) {
            let stages = splitTopLevelPipes(element).map { stage in
                splitSegments(stage.hasPrefix("&") ? String(stage.dropFirst()) : stage).map(tokenizeCommand)
            }
            var upstream: [[CommandToken]] = []
            for (stageIndex, stage) in stages.enumerated() {
                for (index, segment) in stage.enumerated() {
                    let siblings = stage.indices.filter { $0 != index }.map { stage[$0] }
                    let feed = StdinFeed(
                        producers: upstream + siblings, inheritedLiteral: stageIndex > 0 || inherited, line: line
                    )
                    if segmentRunsOpaque(segment, feed: feed, depth: depth) { return true }
                }
                upstream += stage
            }
        }
        return false
    }

    // MARK: Segments

    /// The segment a command came from, its stdin, and the scan depth.
    struct Context {
        let segment: [CommandToken]
        let feed: StdinFeed
        let depth: Int
    }

    private static func segmentRunsOpaque(_ tokens: [CommandToken], feed: StdinFeed, depth: Int) -> Bool {
        switch commandStart(tokens) {
        case .none:
            return false
        case .opaque:
            return true
        case .at(let index):
            return commandRunsOpaque(Array(tokens[index...]), Context(segment: tokens, feed: feed, depth: depth))
        }
    }

    private static func commandRunsOpaque(_ tokens: [CommandToken], _ context: Context) -> Bool {
        guard let headToken = tokens.first else { return false }
        if isDynamic(headToken) { return true }
        let head = basename(headToken.decoded)
        let arguments = Array(tokens.dropFirst())
        let depth = context.depth
        if head == "eval" {
            if arguments.contains(where: isDynamic) { return true }
            let stdinLiteral = stdinIsLiteral(arguments, feed: context.feed)
            return scan(arguments.map(\.decoded).joined(separator: " "), depth: depth + 1, inheritedLiteral: stdinLiteral)
        }
        if head == "source" || head == "." {
            return sourcesOpaque(arguments)
        }
        if shells.contains(head) {
            return shellRunsOpaque(arguments, context)
        }
        if isInterpreter(head) {
            return interpreterRunsOpaque(head, arguments, context)
        }
        switch head {
        case "awk", "gawk", "mawk", "nawk":
            return awkRunsOpaque(arguments)
        case "sed", "gsed":
            return sedRunsOpaque(arguments)
        case "ssh":
            return sshRunsOpaque(arguments, depth: depth, stdinLiteral: stdinIsLiteral(arguments, feed: context.feed))
        case "trap":
            return trapRunsOpaque(arguments, depth: depth)
        case "xargs":
            return verbRunsOpaque(xargsVerb(arguments))
        case "parallel":
            guard let verb = parallelVerb(arguments) else { return true }
            return verbRunsOpaque(verb)
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

    /// Index of the command word after assignments, reserved words and
    /// transparent wrappers. `.opaque` when a wrapper splits a string into
    /// a command (`env -S`) or a word in wrapper position is dynamic.
    static func commandStart(_ tokens: [CommandToken]) -> Start {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let word = token.decoded
            if token.wasQuoted == false, isAssignment(word) || skippedWords.contains(word) {
                index += 1
                continue
            }
            if notCommands.contains(word) { return .none }
            guard let options = wrapperValueOptions[basename(word)], token.wasQuoted == false else {
                return .at(index)
            }
            if basename(word) == "command",
               tokens.dropFirst(index + 1).first.map({ $0.decoded == "-v" || $0.decoded == "-V" }) == true
            {
                return .none
            }
            index += 1
            // The wrapper's options, then its operand slots.
            while index < tokens.count {
                let option = tokens[index]
                if isDynamic(option) { return .opaque }
                let text = option.decoded
                if basename(word) == "env", text == "-S" || text.hasPrefix("-S") || text.hasPrefix("--split-string") {
                    return .opaque
                }
                if text == "--" { index += 1; break }
                guard text.hasPrefix("-"), text.count > 1 else { break }
                index += options.contains(text) ? 2 : 1
            }
            if basename(word) == "timeout", index < tokens.count { index += 1 }
            if basename(word) == "env" {
                while index < tokens.count, tokens[index].wasQuoted == false, isAssignment(tokens[index].decoded) {
                    index += 1
                }
            }
        }
        return .none
    }

    /// Wrappers that run their operand, and the options that take a value.
    private static let wrapperValueOptions: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-U", "-D", "-r", "-t", "-T"],
        "doas": ["-u", "-C"],
        "env": ["-u", "-C", "-P", "--unset", "--chdir"],
        "command": [], "builtin": [], "exec": ["-a"], "nohup": [], "time": [],
        "nice": ["-n", "--adjustment"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"],
        "stdbuf": ["-i", "-o", "-e"],
        "setsid": [], "caffeinate": ["-t", "-w"],
    ]

    private static let skippedWords: Set<String> = [
        "!", "{", "(", "if", "then", "else", "elif", "do", "while", "until", "coproc",
    ]

    /// Heads that start no command: loop headers, closers, tests.
    private static let notCommands: Set<String> = [
        "for", "select", "done", "fi", "esac", "}", ")", "function",
    ]

    // MARK: Runners

    private static func sourcesOpaque(_ arguments: [CommandToken]) -> Bool {
        guard let operand = arguments.first(where: { $0.decoded.hasPrefix("-") == false || $0.decoded == "-" }) else {
            return false
        }
        return isDynamic(operand) || readsStdin(operand.decoded) || operand.decoded.hasPrefix("<(")
    }

    private static func shellRunsOpaque(_ rawArguments: [CommandToken], _ context: Context) -> Bool {
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
                return payloadRunsOpaque(payload, rawArguments, context)
            }
            if text.hasPrefix("--") == false {
                if text.contains("c") { command = true }
                if text.contains("s") { stdin = true }
            }
            index += 1
        }
        if command {
            guard index < arguments.count else { return false }
            return payloadRunsOpaque(arguments[index], rawArguments, context)
        }
        let operand = index < arguments.count && stdin == false ? arguments[index] : nil
        guard let operand, operand.decoded != "-", readsStdin(operand.decoded) == false else {
            // The program is stdin: readable only from literal producers,
            // whose text the lexical floors read.
            return stdinIsLiteral(rawArguments, feed: context.feed) == false
        }
        return isDynamic(operand)
    }

    /// A shell's `-c` script: dynamic or escaped text is unreadable; a
    /// literal one is scanned, inheriting the shell's stdin.
    private static func payloadRunsOpaque(_ payload: CommandToken, _ rawArguments: [CommandToken], _ context: Context) -> Bool {
        if payload.wasAnsiC { return true }
        if payload.wasQuoted == false, isDynamic(payload) { return true }
        if splitSegments(payload.decoded).contains(where: { decodes(tokenizeCommand($0)) }) { return true }
        let stdinLiteral = stdinIsLiteral(rawArguments, feed: context.feed)
        return scan(payload.decoded, depth: context.depth + 1, inheritedLiteral: stdinLiteral)
    }

    private static func interpreterRunsOpaque(_ head: String, _ rawArguments: [CommandToken], _ context: Context) -> Bool {
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
            let text = token.decoded
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
                    || stdinIsLiteral(rawArguments, feed: context.feed) == false
                    || context.segment.contains { isDynamic($0) && $0.decoded != payload.decoded }
            }
        }
        guard let operand, operand.decoded != "-", readsStdin(operand.decoded) == false else {
            // The program is stdin: unreadable unless the producers are
            // literal; then it is judged like inline code.
            guard stdinIsLiteral(rawArguments, feed: context.feed) else { return true }
            let program = readsHeredoc(rawArguments) ? context.feed.line : context.feed.text
            return execsCode(program) && readsUnseen(program)
        }
        return isDynamic(operand)
    }

    /// A here-string with dynamic or ANSI-C content, or `<(…)` as an
    /// operand or redirect source: what the program reads is unseen.
    private static func feedsOpaqueInput(_ arguments: [CommandToken]) -> Bool {
        for (index, token) in arguments.enumerated() {
            let text = token.decoded
            if text.hasPrefix("<(") { return true }
            guard text.hasPrefix("<<<") else { continue }
            let glued = text.dropFirst(3)
            if glued.isEmpty == false {
                if token.wasAnsiC || glued.contains("$") || glued.contains("`") { return true }
            } else if let content = arguments.dropFirst(index + 1).first {
                if content.wasAnsiC || isDynamic(content) { return true }
            }
        }
        return false
    }

    /// The arguments without redirects (`2>/dev/null`, `< in`, `> out`,
    /// `<<EOF`), so a redirect is never read as a script operand.
    static func droppingRedirects(_ arguments: [CommandToken]) -> [CommandToken] {
        var kept: [CommandToken] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            let operatorText = token.decoded.drop(while: { $0.isASCII && ($0.isNumber || $0 == "&") })
            guard token.wasQuoted == false, operatorText.hasPrefix(">") || operatorText.hasPrefix("<") else {
                kept.append(token)
                index += 1
                continue
            }
            let bare = operatorText.allSatisfy { $0 == ">" || $0 == "<" || $0 == "|" || $0 == "&" }
            index += bare ? 2 : 1
        }
        return kept
    }

    /// `xargs [options] verb …`: options that take a value skip it.
    private static func xargsVerb(_ arguments: [CommandToken]) -> [CommandToken] {
        var index = 0
        while index < arguments.count {
            let text = arguments[index].decoded
            if text == "--" { index += 1; break }
            guard text.hasPrefix("-"), text.count > 1 else { break }
            index += xargsValueOptions.contains(text) ? 2 : 1
        }
        return Array(arguments.dropFirst(index))
    }

    private static let xargsValueOptions: Set<String> = [
        "-I", "-i", "-L", "-l", "-n", "-P", "-s", "-d", "-E", "-e", "-a", "-J", "-R", "-S",
        "--delimiter", "--arg-file", "--max-args", "--max-procs", "--max-lines", "--replace",
    ]

    /// `parallel [options] verb … ::: args`: the verb is the words before
    /// the first input separator. nil when there is none: parallel then
    /// runs its input as commands.
    private static func parallelVerb(_ arguments: [CommandToken]) -> [CommandToken]? {
        var index = 0
        while index < arguments.count {
            let text = arguments[index].decoded
            if parallelSeparators.contains(text) { return nil }
            if text == "--" { index += 1; break }
            guard text.hasPrefix("-"), text.count > 1 else { break }
            index += parallelValueOptions.contains(text) ? 2 : 1
        }
        let verb = arguments.dropFirst(index).prefix { parallelSeparators.contains($0.decoded) == false }
        return verb.isEmpty ? nil : Array(verb)
    }

    private static let parallelSeparators: Set<String> = [":::", "::::", ":::+", "::::+"]

    private static let parallelValueOptions: Set<String> = [
        "-j", "-I", "-S", "-d", "-N", "-n", "-L", "-a", "-P", "-E",
        "--jobs", "--colsep", "--arg-file", "--delimiter", "--sshlogin", "--joblog", "--results",
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
            let head = basename(token.decoded)
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

    private static let lifecycleVerbs: Set<String> = ["kill", "pkill", "killall", "launchctl", "rv", "rvd", "systemctl"]

    // MARK: Decoders

    /// The segment turns unreadable bytes into text: a decoder, an escape
    /// expansion, or a fetch. An extra signal for `-c` scripts only; it
    /// never decides that a command is readable.
    private static func decodes(_ tokens: [CommandToken]) -> Bool {
        if tokens.contains(where: { $0.wasAnsiC && $0.decoded.contains("\\") }) { return true }
        guard case .at(let index) = commandStart(tokens) else { return false }
        let head = basename(tokens[index].decoded)
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

    private static let shells: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "ash", "yash", "csh", "tcsh",
    ]

    private static func isInterpreter(_ head: String) -> Bool {
        head.hasPrefix("python") || head.hasPrefix("pypy")
            || ["node", "nodejs", "bun", "deno", "ruby", "perl", "php", "lua", "luajit", "osascript", "Rscript", "tclsh", "pwsh"]
            .contains(head)
    }

    private static func inlineFlags(_ head: String) -> Set<String> {
        if head.hasPrefix("python") || head.hasPrefix("pypy") { return ["-c"] }
        switch head {
        case "node", "nodejs", "bun": return ["-e", "-p", "--eval", "--print"]
        case "php": return ["-r"]
        case "perl": return ["-e", "-E"]
        case "Rscript": return ["-e"]
        case "pwsh": return ["-c", "-Command", "-EncodedCommand", "-e"]
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

    static func isDynamic(_ token: CommandToken) -> Bool {
        token.decoded.contains("$") || token.decoded.contains("`")
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

    static func basename(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }
}

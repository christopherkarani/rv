import RVDomain

/// Observe floor: true when part of `command` that rv cannot read can
/// occupy a command position, so the line may run any program at all.
///
/// Floored: a dynamic command word (`$x`, `$(…)`, backticks); `eval` of
/// dynamic text; `source`/`.` of stdin, a descriptor or `<(…)`; a shell or
/// interpreter running a dynamic script operand, `<(…)`, a dynamic
/// here-string, dynamic or encoded inline code, or stdin in a line that
/// decodes or fetches; `xargs`, `find -exec` and `parallel` whose verb is a
/// shell, an interpreter, `eval`, `source`, `env -S` or dynamic (or no verb
/// for `parallel`, which then runs its input). A literal verb with dynamic
/// arguments (`xargs rm`) and an inner script whose command heads are all
/// literal are not floored: the lexical observe floors read that text.
package func runsOpaqueProgram(_ command: ShellCommand) -> Bool {
    OpaqueExecution.scan(command.rawValue, depth: 0)
}

enum OpaqueExecution {
    private static let maxDepth = 4

    static func scan(_ text: String, depth: Int) -> Bool {
        guard depth <= maxDepth else { return true }
        let segments = splitSegments(text)
        let lineDecodes = segments.contains { decodes(tokenizeCommand($0)) }
        return segments.contains { segment in
            segmentRunsOpaque(tokenizeCommand(segment), lineDecodes: lineDecodes, depth: depth)
        }
    }

    // MARK: Segments

    private static func segmentRunsOpaque(_ tokens: [CommandToken], lineDecodes: Bool, depth: Int) -> Bool {
        switch commandStart(tokens) {
        case .none:
            return false
        case .opaque:
            return true
        case .at(let index):
            return commandRunsOpaque(Array(tokens[index...]), lineDecodes: lineDecodes, depth: depth)
        }
    }

    private static func commandRunsOpaque(_ tokens: [CommandToken], lineDecodes: Bool, depth: Int) -> Bool {
        guard let headToken = tokens.first else { return false }
        if isDynamic(headToken) { return true }
        let head = basename(headToken.decoded)
        let arguments = Array(tokens.dropFirst())
        if head == "eval" {
            if arguments.contains(where: isDynamic) { return true }
            return scan(arguments.map(\.decoded).joined(separator: " "), depth: depth + 1)
        }
        if head == "source" || head == "." {
            return sourcesOpaque(arguments)
        }
        if shells.contains(head) {
            return shellRunsOpaque(arguments, lineDecodes: lineDecodes, depth: depth)
        }
        if isInterpreter(head) {
            return interpreterRunsOpaque(head, arguments, lineDecodes: lineDecodes)
        }
        switch head {
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

    private enum Start {
        case none
        case opaque
        case at(Int)
    }

    /// Index of the command word after assignments, reserved words and
    /// transparent wrappers. `.opaque` when a wrapper splits a string into
    /// a command (`env -S`) or a word in wrapper position is dynamic.
    private static func commandStart(_ tokens: [CommandToken]) -> Start {
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

    private static func shellRunsOpaque(_ rawArguments: [CommandToken], lineDecodes: Bool, depth: Int) -> Bool {
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
            if text.hasPrefix("--") == false {
                if text.contains("c") { command = true }
                if text.contains("s") { stdin = true }
            }
            index += 1
        }
        if command {
            guard index < arguments.count else { return false }
            let payload = arguments[index]
            if payload.wasAnsiC { return true }
            if payload.wasQuoted == false, isDynamic(payload) { return true }
            if splitSegments(payload.decoded).contains(where: { decodes(tokenizeCommand($0)) }) { return true }
            return scan(payload.decoded, depth: depth + 1)
        }
        let operand = index < arguments.count && stdin == false ? arguments[index] : nil
        guard let operand, operand.decoded != "-", readsStdin(operand.decoded) == false else {
            return lineDecodes
        }
        return isDynamic(operand)
    }

    private static func interpreterRunsOpaque(_ head: String, _ rawArguments: [CommandToken], lineDecodes: Bool) -> Bool {
        if feedsOpaqueInput(rawArguments) { return true }
        let arguments = droppingRedirects(rawArguments)
        let inline = inlineFlags(head)
        var payloads: [CommandToken] = []
        var operand: CommandToken?
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
                payload.wasAnsiC
                    || carriesSubstitution(payload.decoded)
                    || payload.decoded.hasPrefix("$")
                    || (payload.wasQuoted == false && payload.decoded.contains("$"))
                    || (execsCode(payload.decoded) && (decodesCode(payload.decoded) || lineDecodes))
            }
        }
        guard let operand, operand.decoded != "-", readsStdin(operand.decoded) == false else {
            return lineDecodes
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
    private static func droppingRedirects(_ arguments: [CommandToken]) -> [CommandToken] {
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

    /// `parallel [options] verb …`, or nil when it runs its input lines.
    private static func parallelVerb(_ arguments: [CommandToken]) -> [CommandToken]? {
        var index = 0
        while index < arguments.count {
            let text = arguments[index].decoded
            if text == ":::" || text == "::::" || text == ":::+" { return nil }
            guard text.hasPrefix("-"), text.count > 1 else { break }
            index += parallelValueOptions.contains(text) ? 2 : 1
        }
        let verb = Array(arguments.dropFirst(index))
        return verb.isEmpty ? nil : verb
    }

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
            return shells.contains(head) || isInterpreter(head)
                || ["eval", "source", ".", "xargs", "parallel", "find"].contains(head)
        }
    }

    // MARK: Decoders

    /// The segment turns unreadable bytes into text: a decoder, an escape
    /// expansion, or a fetch. Only matters where that text may run.
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
        case "openssl", "rev", "tr", "uudecode", "gunzip", "zcat", "bzcat", "xzcat", "unxz", "bunzip2",
             "zstdcat", "unzstd", "curl", "wget":
            return true
        case "base64", "gbase64", "basenc":
            return hasShortFlag(["d", "D"]) || flags.contains("--decode")
        case "xxd":
            return hasShortFlag(["r"])
        case "gzip", "bzip2", "xz", "zstd":
            return hasShortFlag(["d"]) || flags.contains("--decompress") || flags.contains("--decode")
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

    /// Inline code that decodes bytes into text.
    private static func decodesCode(_ code: String) -> Bool {
        decodeMarkers.contains { code.contains($0) }
    }

    private static let execMarkers = [
        "system(", "exec(", "eval(", "popen", "spawn", "subprocess", "execSync", "child_process",
        "do shell script", "shell_exec", "passthru", "proc_open", "os.execute", "io.popen", "`",
        "execv", "Process(", "Kernel.", "IO.popen", "compile(", "__import__",
    ]

    private static let decodeMarkers = [
        "b64decode", "base64", "decodebytes", "a85decode", "b32decode", "fromhex", "unhexlify",
        "codecs", "zlib", "Buffer.from", "atob", "pack(", "decode_base64", "chr(", "fromCharCode",
        "rot13", "[::-1]", "reverse", "gzinflate", "hex2bin", "\\x",
    ]

    // MARK: Words

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "ash", "mksh", "yash"]

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

    private static func isDynamic(_ token: CommandToken) -> Bool {
        token.decoded.contains("$") || token.decoded.contains("`")
    }

    private static func readsStdin(_ path: String) -> Bool {
        path == "-" || path == "/dev/stdin" || path.hasPrefix("/dev/fd/") || path.hasPrefix("/proc/self/fd/")
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, assignmentNameStart.contains(first) else { return false }
        return name.allSatisfy { assignmentNameChars.contains($0) || $0 == "+" && name.last == "+" }
    }

    private static func basename(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }
}

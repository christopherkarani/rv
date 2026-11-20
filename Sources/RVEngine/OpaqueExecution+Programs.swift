import RVDomain

/// Programs that run text as a command from inside their own language:
/// `awk` (`system`, a pipe to or from a command), `sed` (the `e` flag or
/// command), `ssh` (the remote command, and local `ProxyCommand`-style
/// options) and `trap` (its action runs later as a script).
extension OpaqueExecution {
    // MARK: awk

    /// `awk` whose program runs a command: it can build that command from
    /// any text it reads or concatenates, so it is floored whatever feeds
    /// it. A dynamic program is floored too.
    static func awkRunsOpaque(_ rawArguments: [CommandToken]) -> Bool {
        let arguments = droppingRedirects(rawArguments)
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            let text = token.decoded
            if text == "--" { index += 1; break }
            guard text.hasPrefix("-"), text.count > 1, token.wasQuoted == false else { break }
            if text == "-f" || text == "--file" { return arguments.dropFirst(index + 1).first.map(isDynamic) ?? false }
            index += awkValueOptions.contains(text) ? 2 : 1
        }
        guard index < arguments.count else { return false }
        let program = arguments[index]
        if program.wasAnsiC || carriesSubstitution(program.decoded) { return true }
        if program.wasQuoted == false, program.decoded.contains("$") { return true }
        return awkRunsCommand(program.decoded)
    }

    private static let awkValueOptions: Set<String> = ["-F", "-v", "-W", "--field-separator", "--assign"]

    /// `system(…)`, or a `|` that pipes to or from a command (`print |
    /// "sh"`, `"cmd" | getline`); `||` is logical or.
    private static func awkRunsCommand(_ program: String) -> Bool {
        if program.contains("system") { return true }
        let scalars = Array(program.unicodeScalars)
        return scalars.indices.contains { index in
            scalars[index] == "|"
                && (index == 0 || scalars[index - 1] != "|")
                && (index + 1 == scalars.count || scalars[index + 1] != "|")
        }
    }

    // MARK: sed

    /// GNU `sed` with the `e` command or an `s///e` flag runs the pattern
    /// space as a command, so any input (or a transform of a literal one)
    /// can run anything. A dynamic script is floored too; a script file
    /// (`-f`) is unread, like a script operand.
    static func sedRunsOpaque(_ rawArguments: [CommandToken]) -> Bool {
        let arguments = droppingRedirects(rawArguments)
        var scripts: [CommandToken] = []
        var sawScriptFlag = false
        var firstOperand: CommandToken?
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            let text = token.decoded
            if token.wasQuoted == false, text == "-e" || text == "--expression" {
                sawScriptFlag = true
                if index + 1 < arguments.count { scripts.append(arguments[index + 1]) }
                index += 2
                continue
            }
            if token.wasQuoted == false, text.hasPrefix("--expression=") {
                sawScriptFlag = true
                scripts.append(CommandToken(decoded: String(text.dropFirst("--expression=".count)), wasQuoted: true))
                index += 1
                continue
            }
            if token.wasQuoted == false, text == "-f" || text == "--file" || text.hasPrefix("--file=") {
                sawScriptFlag = true
                index += text.contains("=") ? 1 : 2
                continue
            }
            if token.wasQuoted == false, text == "-i",
               let suffix = arguments.dropFirst(index + 1).first, suffix.decoded.isEmpty || suffix.decoded.hasPrefix(".")
            {
                // BSD `-i ''` / `-i .bak` take a suffix word.
                index += 2
                continue
            }
            if token.wasQuoted == false, text.hasPrefix("-"), text.count > 1 {
                index += 1
                continue
            }
            if firstOperand == nil, token.decoded.isEmpty == false { firstOperand = token }
            index += 1
        }
        if sawScriptFlag == false, let firstOperand { scripts.append(firstOperand) }
        return scripts.contains { script in
            script.wasAnsiC || carriesSubstitution(script.decoded)
                || (script.wasQuoted == false && script.decoded.contains("$"))
                || sedScriptExecutes(script.decoded)
        }
    }

    /// Walks the script's commands: an `e` command, or an `s` command whose
    /// flags include `e`. Addresses, `y///`, text and label arguments are
    /// skipped; an unparsed tail is read as executing (fail closed).
    static func sedScriptExecutes(_ script: String) -> Bool {
        let scalars = Array(script.unicodeScalars)
        var index = 0
        func skipDelimited(_ delimiter: Unicode.Scalar) -> Bool {
            while index < scalars.count {
                if scalars[index] == "\\" { index += 2; continue }
                if scalars[index] == delimiter { index += 1; return true }
                index += 1
            }
            return false
        }
        func skipToCommandEnd() {
            while index < scalars.count, scalars[index] != "\n", scalars[index] != ";" { index += 1 }
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == ";" || scalar == "{" || scalar == "}"
                || scalar == "!" || scalar == ","
            {
                index += 1
                continue
            }
            // Addresses: line numbers, `$`, steps, `/re/`, `\cREc`.
            if ("0"..."9").contains(scalar) || scalar == "$" || scalar == "~" || scalar == "+" {
                index += 1
                continue
            }
            if scalar == "/" {
                index += 1
                guard skipDelimited("/") else { return true }
                while index < scalars.count, scalars[index] == "I" || scalars[index] == "M" { index += 1 }
                continue
            }
            if scalar == "\\", index + 1 < scalars.count {
                let delimiter = scalars[index + 1]
                index += 2
                guard skipDelimited(delimiter) else { return true }
                continue
            }
            switch scalar {
            case "e":
                return true
            case "s", "y":
                guard index + 1 < scalars.count else { return true }
                let delimiter = scalars[index + 1]
                index += 2
                guard skipDelimited(delimiter), skipDelimited(delimiter) else { return true }
                guard scalar == "s" else { continue }
                var flags = ""
                while index < scalars.count, scalars[index] != ";", scalars[index] != "\n", scalars[index] != "}" {
                    if scalars[index] == "w" { skipToCommandEnd(); break }
                    flags.unicodeScalars.append(scalars[index])
                    index += 1
                }
                if flags.contains("e") { return true }
            case "a", "i", "c", "r", "R", "w", "W", "b", "t", "T", ":", "l", "L", "q", "Q", "v", "z", "F":
                // Text, file or label arguments run to the end of the command.
                index += 1
                if scalar == "a" || scalar == "i" || scalar == "c" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else {
                    skipToCommandEnd()
                }
            default:
                index += 1
            }
        }
        return false
    }

    // MARK: ssh

    /// `ssh host <command>`: the remote shell re-parses the command, so a
    /// dynamic word anywhere in it is code (`ssh localhost "$X"` runs
    /// locally). A literal command is scanned like `sh -c`. Local-command
    /// options (`ProxyCommand`, `LocalCommand`, `KnownHostsCommand`,
    /// `RemoteCommand`) are scanned too.
    static func sshRunsOpaque(_ rawArguments: [CommandToken], depth: Int, inherited: @escaping () -> Feed, state: inout ScanState) -> Bool {
        let arguments = droppingRedirects(rawArguments)
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            let text = token.decoded
            if text == "--" { index += 1; break }
            guard text.hasPrefix("-"), text.count > 1, token.wasQuoted == false else { break }
            if text == "-o" || text.hasPrefix("-o") {
                let value = text == "-o" ? arguments.dropFirst(index + 1).first : CommandToken(decoded: String(text.dropFirst(2)), wasQuoted: true)
                if let value, sshOptionRunsOpaque(value, depth: depth, state: &state) { return true }
                index += text == "-o" ? 2 : 1
                continue
            }
            index += sshValueOptions.contains(text) ? 2 : 1
        }
        let remote = arguments.dropFirst(index + 1)
        guard remote.isEmpty == false else { return false }
        if remote.contains(where: { isDynamic($0) || $0.wasAnsiC }) { return true }
        return scan(remote.map(\.decoded).joined(separator: " "), depth: depth + 1, inherited: inherited, state: &state)
    }

    private static let sshValueOptions: Set<String> = [
        "-b", "-B", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-P", "-p",
        "-Q", "-R", "-S", "-W", "-w",
    ]

    private static let sshCommandOptions: Set<String> = [
        "proxycommand", "localcommand", "knownhostscommand", "remotecommand",
    ]

    private static func sshOptionRunsOpaque(_ option: CommandToken, depth: Int, state: inout ScanState) -> Bool {
        let text = option.decoded
        let key = text.prefix { $0 != "=" && $0 != " " && $0 != "\t" }
        guard sshCommandOptions.contains(key.lowercased()) else { return false }
        if isDynamic(option) || option.wasAnsiC { return true }
        let value = text.dropFirst(key.count).drop { $0 == "=" || $0 == " " || $0 == "\t" }
        return scan(String(value), depth: depth + 1, inherited: { .unreadable }, state: &state)
    }

    // MARK: Schedulers

    /// `at`, `batch` and `crontab` run the job they read from stdin later,
    /// so they are stdin readers like a shell: unreadable input is opaque,
    /// and a literal feed is recorded and scanned like a shell's program
    /// (a crontab's commands without their schedule fields). A job in a
    /// literal file (`at -f job.sh`, `crontab jobs.txt`) is not read, as
    /// for `sh job.sh`; listing or removing jobs (`at -l`, `crontab -r`)
    /// reads no job.
    static func schedulerRunsOpaque(
        _ head: String, _ rawArguments: [CommandToken], _ context: Context, state: inout ScanState
    ) -> Bool {
        let arguments = droppingRedirects(rawArguments)
        let crontab = head == "crontab"
        let modes: Set<Character> = crontab ? ["l", "r", "e", "c", "V"] : ["l", "d", "r", "c"]
        let valued: Set<Character> = crontab ? ["u"] : ["q", "f", "t"]
        var file: CommandToken?
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            let text = token.decoded
            if text == "--" {
                if crontab { file = arguments.dropFirst(index + 1).first }
                break
            }
            guard text.hasPrefix("-"), text.count > 1, token.wasQuoted == false else {
                // crontab's operand is the job file; at's are the time.
                if crontab {
                    file = token
                    break
                }
                index += 1
                continue
            }
            var skip = 1
            for (offset, flag) in text.dropFirst().enumerated() {
                if modes.contains(flag) { return false }
                guard valued.contains(flag) else { continue }
                let rest = String(text.dropFirst(offset + 2))
                let value = rest.isEmpty ? arguments.dropFirst(index + 1).first : CommandToken(decoded: rest, wasQuoted: false)
                if rest.isEmpty { skip = 2 }
                if flag == "f" { file = value }
                break
            }
            index += skip
        }
        if let file, file.decoded != "-", readsStdin(file.decoded) == false {
            return isDynamic(file)
        }
        let fed = context.stdin()
        guard fed.literal else { return true }
        return fed.texts.contains { text in
            literalProgramRunsOpaque(crontab ? crontabCommands(text) : text, context, state: &state)
        }
    }

    /// A crontab's commands, one per line: the schedule (five fields, or
    /// one `@` word) dropped; comments and blank lines skipped; a variable
    /// setting or a line too short for a schedule kept whole. cron turns an
    /// unescaped `%` into a newline (the rest is the command's stdin), so
    /// it is read as one.
    static func crontabCommands(_ text: String) -> String {
        var commands: [String] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = trimmed.first, first != "#" else { continue }
            let firstWord = trimmed.prefix(while: { $0 != " " && $0 != "\t" })
            var rest = trimmed
            if firstWord.contains("=") == false {
                for _ in 0..<(first == "@" ? 1 : 5) {
                    rest = rest.drop(while: { $0 != " " && $0 != "\t" }).drop(while: { $0 == " " || $0 == "\t" })
                }
            }
            let command = rest.isEmpty ? trimmed : rest
            commands.append(cronPercents(String(command)))
        }
        return commands.joined(separator: "\n")
    }

    /// `%` → newline, `\%` → `%`.
    private static func cronPercents(_ command: String) -> String {
        var out = ""
        var escaped = false
        for character in command {
            if escaped {
                if character != "%" { out.append("\\") }
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character == "%" ? "\n" : character)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    // MARK: trap

    /// `trap <action> <signal…>`: the action runs later as a script, so it
    /// is scanned; a dynamic action (`trap "$X" EXIT`) is a dynamic head.
    static func trapRunsOpaque(_ arguments: [CommandToken], depth: Int, state: inout ScanState) -> Bool {
        var index = 0
        while index < arguments.count {
            let text = arguments[index].decoded
            if text == "--" { index += 1; break }
            guard text == "-p" || text == "-l" || text == "-P" else { break }
            index += 1
        }
        guard index < arguments.count else { return false }
        let action = arguments[index]
        if action.wasAnsiC { return true }
        return scan(action.decoded, depth: depth + 1, inherited: { .unreadable }, state: &state)
    }
}

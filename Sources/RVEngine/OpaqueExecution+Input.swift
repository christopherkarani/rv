import Foundation
import RVDomain

/// Where a stdin reader's input comes from, and whether rv can read it.
///
/// A program reading its program from stdin runs what it is fed. That is
/// readable only from a literal here-string, a literal heredoc, or
/// producers that are all literal: `echo`/`printf` without escapes, a `cat`
/// of literal paths (whose text is a script file rv does not read) or of a
/// literal heredoc, behind any transparent wrapper. In a pipeline the
/// producers are the stages before the reader; in a compound command,
/// group or function body (where rv does not track the plumbing) they are
/// every other command of the text. Anything else (a decoder, a transform
/// like `sed`/`tr`/`rev`, a fetch, an expansion, `exec < …`) is unreadable,
/// so the reader is floored. A literal feed is not trusted blind: its text
/// is scanned like the line and read by the stop floor.
extension OpaqueExecution {
    /// What `segment`'s command reads on stdin: its own redirect (a
    /// here-string, a heredoc, a file, a descriptor), else `feed`. As in
    /// the shell, only a redirect of fd 0 (`<`, `0<`) replaces stdin and
    /// the last one wins; another fd (`3</dev/null`, `{fd}<f`) leaves it
    /// alone. A heredoc is read only when it is the segment's last (the
    /// body `heredoc` holds); a descriptor (`<&`, `/dev/fd/3`) is
    /// unreadable.
    static func stdin(_ segment: [CommandToken], heredoc: ShellLexer.Heredoc?, feed: () -> Feed) -> Feed {
        let lastHeredoc = segment.lastIndex { token in
            ShellLexer.isRedirectOperator(token) && ["<<", "<<-"].contains(redirectOperator(token.decoded))
        }
        var input: Feed?
        for (index, token) in segment.enumerated() where ShellLexer.isRedirectOperator(token) {
            guard redirectsStdin(token.decoded) else { continue }
            let target = segment.dropFirst(index + 1).first
            switch redirectOperator(token.decoded) {
            case "<<<":
                guard let target, target.wasAnsiC == false, isDynamic(target) == false else {
                    input = .unreadable
                    continue
                }
                input = Feed(literal: true, text: target.decoded + "\n")
            case "<<", "<<-":
                guard index == lastHeredoc, let heredoc else {
                    input = .unreadable
                    continue
                }
                input = Feed(literal: heredoc.literal, text: heredoc.literal ? heredoc.body + "\n" : "")
            case "<", "<>":
                guard let target, isDynamic(target) == false else {
                    input = .unreadable
                    continue
                }
                if readsOwnStdin(target.decoded) {
                    // fd 0 as the redirects before left it.
                    input = input ?? feed()
                } else if readsStdin(target.decoded) {
                    input = .unreadable
                } else {
                    // A literal file: a script rv does not read.
                    input = .empty
                }
            default:
                // `<&`: a descriptor.
                input = .unreadable
            }
        }
        return input ?? feed()
    }

    /// An input redirect of fd 0: no fd, or one spelled all zeros (`0<`,
    /// `00<&3`). Output redirects and any other fd, numbered or named
    /// (`3<`, `{fd}<`), are not.
    private static func redirectsStdin(_ word: String) -> Bool {
        let fd = redirectFD(word)
        guard redirectOperator(word).hasPrefix("<") else { return false }
        return fd.allSatisfy { $0 == "0" }
    }

    /// `-`, `/dev/stdin` and fd 0 by path read fd 0 itself.
    private static func readsOwnStdin(_ path: String) -> Bool {
        path == "-" || path == "/dev/stdin" || path == "/dev/fd/0" || path == "/proc/self/fd/0"
    }

    /// The redirect operator part of a word: `0<&` → `<&`, `{fd}<` → `<`.
    static func redirectOperator(_ word: String) -> Substring {
        word.dropFirst(redirectFD(word).count)
    }

    /// The fd a redirect word names: its digits (`2>`), or a bash/zsh
    /// named fd (`{fd}<`); empty for none.
    static func redirectFD(_ word: String) -> Substring {
        if word.first == "{", let close = word.firstIndex(of: "}"),
           isFDName(word[word.index(after: word.startIndex)..<close])
        {
            return word[...close]
        }
        return word.prefix(while: { $0.isASCII && $0.isNumber })
    }

    /// A shell variable name, as `{name}` takes.
    static func isFDName(_ name: Substring) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    // MARK: Producers

    /// What a command writes to a reader, when rv can read it: nil for
    /// anything it cannot. A command that runs nothing (`fi`, `X=1`, a
    /// group's redirects) passes on only the input it redirects in.
    static func producerOutput(_ command: LineCommand) -> String? {
        if command.tokens.contains(where: { isDynamic($0) || $0.wasAnsiC }) { return nil }
        switch commandStart(command.tokens) {
        case .opaque:
            return nil
        case .none:
            let input = stdin(command.tokens, heredoc: command.heredoc, feed: { .empty })
            return input.literal ? input.text : nil
        case .at(let index):
            return literalOutput(Array(command.tokens[index...]), heredoc: command.heredoc)
        }
    }

    /// What a literal producer emits: `echo` with no backslash, `printf`
    /// with no `%` and no escape but `\n`, `cat` of literal paths (its text
    /// is unread, so ""), `cat` of a literal heredoc or here-string.
    static func literalOutput(_ tokens: [CommandToken], heredoc: ShellLexer.Heredoc?) -> String? {
        guard let head = tokens.first else { return nil }
        let arguments = droppingRedirects(Array(tokens.dropFirst()))
        switch commandName(head.decoded) {
        case "echo":
            guard arguments.allSatisfy({ $0.decoded.contains("\\") == false }) else { return nil }
            let flags = arguments.prefix(while: { echoFlags.contains($0.decoded) })
            let words = arguments.dropFirst(flags.count).map(\.decoded).joined(separator: " ")
            return flags.contains(where: { $0.decoded.contains("n") }) ? words : words + "\n"
        case "printf":
            // No conversion: the format is printed once, extra words unused.
            let words = arguments.first?.decoded == "--" ? Array(arguments.dropFirst()) : arguments
            guard let format = words.first?.decoded, format.hasPrefix("-") == false, printfIsPlain(format) else {
                return nil
            }
            return format.replacingOccurrences(of: "\\n", with: "\n")
        case "cat":
            let files = arguments.filter { $0.decoded.hasPrefix("-") == false || $0.decoded == "-" }
            if files.isEmpty {
                let input = stdin(tokens, heredoc: heredoc, feed: { .unreadable })
                return input.literal ? input.text : nil
            }
            return files.contains(where: { readsStdin($0.decoded) }) ? nil : ""
        case let name where silentCommands.contains(name):
            // Writes nothing but, in an error or a `cd` path, its own
            // words: those stand in for its output.
            if arguments.isEmpty, silentOnlyWithArguments.contains(name) { return nil }
            if name == "cd", arguments.contains(where: { $0.decoded == "-" }) { return nil }
            return arguments.isEmpty ? "" : arguments.map(\.decoded).joined(separator: " ") + "\n"
        default:
            return nil
        }
    }

    private static let silentCommands: Set<String> = [
        "cd", "true", "false", ":", "test", "[", "[[", "export", "unset", "local", "readonly", "shift",
        "exit", "return", "sleep", "wait", "set",
    ]

    /// With no arguments these print the variables or options.
    private static let silentOnlyWithArguments: Set<String> = ["export", "readonly", "local", "set"]

    private static let echoFlags: Set<String> = ["-n", "-e", "-E", "-ne", "-en", "-nE", "-En"]

    /// No format directive and no escape but `\n`: the text printed is
    /// the text written.
    private static func printfIsPlain(_ text: String) -> Bool {
        text.contains("%") == false && text.replacingOccurrences(of: "\\n", with: "").contains("\\") == false
    }
}

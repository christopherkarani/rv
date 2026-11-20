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
    /// here-string, a heredoc, a file, a descriptor), else `feed`.
    static func stdin(_ segment: [CommandToken], heredoc: ShellLexer.Heredoc?, feed: () -> Feed) -> Feed {
        for (index, token) in segment.enumerated() where ShellLexer.isRedirectOperator(token) {
            let target = segment.dropFirst(index + 1).first
            switch redirectOperator(token.decoded) {
            case "<<<":
                guard let target, target.wasAnsiC == false, isDynamic(target) == false else { return .unreadable }
                return Feed(literal: true, text: target.decoded + "\n")
            case "<<", "<<-":
                guard let heredoc else { return .unreadable }
                return Feed(literal: heredoc.literal, text: heredoc.literal ? heredoc.body + "\n" : "")
            case "<&":
                return .unreadable
            case "<", "<>":
                guard let target, isDynamic(target) == false else { return .unreadable }
                // A literal file: a script rv does not read.
                return readsStdin(target.decoded) ? feed() : .empty
            default:
                continue
            }
        }
        return feed()
    }

    /// The redirect operator part of a word: `0<&` → `<&`.
    static func redirectOperator(_ word: String) -> Substring {
        word.drop(while: { $0.isASCII && $0.isNumber })
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

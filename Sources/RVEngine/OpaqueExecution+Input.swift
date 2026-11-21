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
    /// What `segment`'s command reads on stdin. rv models no shell's way
    /// of combining redirects (zsh MULTIOS joins every input and the
    /// pipe; bash 3.2 and dash read `{fd}<` as a word and fd 0), so stdin
    /// is read only from one unambiguous source and is unreadable
    /// otherwise, never "the last one" and never empty:
    /// - no input redirect at all: `feed` (the pipe, or the text's own
    ///   stdin);
    /// - else, with no pipe, exactly one input redirect, of fd 0
    ///   (unnumbered or `0`): a literal here-string or heredoc is read; a
    ///   literal file (`< script.sh`) is a script rv does not read, as for
    ///   `sh script.sh`.
    /// A pipe beside a redirect, a second input redirect, a numbered or
    /// named one (`3<…`, `{fd}<…`), a duplicate or redirect of fd 0 (`<&3`,
    /// `0>&3`), `<>` and a descriptor path (`< /dev/stdin`) are unreadable.
    static func stdin(_ segment: [CommandToken], heredoc: ShellLexer.Heredoc?, piped: Bool, feed: () -> Feed) -> Feed {
        let inputs = segment.indices.filter { touchesInput(segment, at: $0) }
        guard let only = inputs.first else { return feed() }
        guard inputs.count == 1, piped == false else { return .unreadable }
        let word = segment[only].decoded
        let fd = redirectFD(word)
        guard fd.allSatisfy({ $0 == "0" }) else { return .unreadable }
        guard let target = segment.dropFirst(only + 1).first, ShellLexer.isRedirectOperator(target) == false else {
            return .unreadable
        }
        switch redirectOperator(word) {
        case "<<<":
            guard target.wasAnsiC == false, isDynamic(target) == false else { return .unreadable }
            return Feed(literal: true, text: target.decoded + "\n")
        case "<<", "<<-":
            guard let heredoc else { return .unreadable }
            return Feed(literal: heredoc.literal, text: heredoc.literal ? heredoc.body + "\n" : "")
        case "<":
            guard isDynamic(target) == false, isProcessSubstitution(target.decoded) == false,
                  readsStdin(target.decoded) == false
            else { return .unreadable }
            // A literal file: a script rv does not read.
            return .empty
        default:
            return .unreadable
        }
    }

    /// Whether the command redirects any input: see `touchesInput`.
    static func redirectsInput(_ segment: [CommandToken]) -> Bool {
        segment.indices.contains { touchesInput(segment, at: $0) }
    }

    /// A redirect on the input side, or one that involves fd 0: any `<`
    /// operator (`<`, `<<`, `<<<`, `<&`, `<>`, numbered or not), any
    /// named one (`{fd}>…`), any of fd 0 by number (`0>&3`) and a
    /// duplicate of fd 0 (`2>&0`).
    private static func touchesInput(_ segment: [CommandToken], at index: Int) -> Bool {
        let token = segment[index]
        guard ShellLexer.isRedirectOperator(token) else { return false }
        let fd = redirectFD(token.decoded)
        let op = redirectOperator(token.decoded)
        if op.hasPrefix("<") || fd.first == "{" { return true }
        if fd.isEmpty == false, fd.allSatisfy({ $0 == "0" }) { return true }
        if op == ">&", let target = segment.dropFirst(index + 1).first?.decoded {
            return target.isEmpty == false && target.allSatisfy { $0 == "0" }
        }
        return false
    }

    /// The redirect operator part of a word: `0<&` → `<&`, `{fd}<` → `<`.
    static func redirectOperator(_ word: String) -> Substring {
        word.dropFirst(redirectFD(word).count)
    }

    /// The fd a redirect word names: its digits (`2>`), or a `{name}`
    /// (bash 4.1+ and zsh open a new fd; bash 3.2 and dash read a word and
    /// fd 0, so a named redirect only ever makes stdin unreadable); empty
    /// for none. Split out so a leading `{fd}<f` is never read as the
    /// command word.
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
            let input = stdin(command.tokens, heredoc: command.heredoc, piped: command.stage > 0, feed: { .empty })
            return input.literal ? input.text : nil
        case .at(let index):
            return literalOutput(Array(command.tokens[index...]), heredoc: command.heredoc, piped: command.stage > 0)
        }
    }

    /// What a literal producer emits: `echo` with no backslash, `printf`
    /// with no `%` and no escape but `\n`, `cat` of literal paths (its text
    /// is unread, so ""), `cat` of a literal heredoc or here-string.
    static func literalOutput(_ tokens: [CommandToken], heredoc: ShellLexer.Heredoc?, piped: Bool) -> String? {
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
                let input = stdin(tokens, heredoc: heredoc, piped: piped, feed: { .unreadable })
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

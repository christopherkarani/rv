import Foundation
import RVDomain

/// Where a stdin reader's input comes from, and whether rv can read it.
///
/// A program reading its program or data from stdin runs what its
/// producers emit. That is readable only when every producer upstream in
/// its pipeline (and every other command in its own stage) is a literal
/// `echo`/`printf` without escapes or a `cat` of literal paths, and the
/// line did not re-point stdin (`exec < …`). Anything else (a decoder, a
/// transform like `sed`/`tr`/`rev`, an interpreter's output, a fetch, a
/// substitution) is unreadable, so the reader is floored.
struct StdinFeed {
    /// Every command that may write to the reader's stdin.
    let producers: [[CommandToken]]
    /// Whether the stdin the pipeline starts with is readable.
    let inheritedLiteral: Bool
    /// The whole line, for a reader fed by a heredoc.
    let line: String

    var isLiteral: Bool {
        inheritedLiteral && producers.allSatisfy(OpaqueExecution.isLiteralOrInert)
    }

    /// What the literal producers emit (`cat` contributes nothing: its
    /// files are not read).
    var text: String {
        producers.compactMap(OpaqueExecution.literalOutput).joined(separator: "\n")
    }
}

extension OpaqueExecution {
    // MARK: Line structure

    /// Backslash-newline continuations removed, as the shell removes them
    /// before splitting words, so `base64 \<LF>-d` is one command. Only an
    /// unescaped backslash outside single quotes and comments continues a
    /// line; `a\\<LF>b` stays two commands.
    static func joiningContinuations(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        var quote: Unicode.Scalar?
        var ansiC = false
        while index < scalars.count {
            let scalar = scalars[index]
            if let open = quote {
                out.append(scalar)
                if open == "'" && ansiC == false {
                    if scalar == "'" { quote = nil }
                    index += 1
                    continue
                }
                if scalar == "\\", index + 1 < scalars.count {
                    if open == "\"", let skip = continuationLength(scalars, after: index) {
                        out.removeLast()
                        index += 1 + skip
                        continue
                    }
                    out.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if scalar == open { quote = nil; ansiC = false }
                index += 1
                continue
            }
            if scalar == "\\" {
                if let skip = continuationLength(scalars, after: index) {
                    index += 1 + skip
                    continue
                }
                out.append(scalar)
                if index + 1 < scalars.count { out.append(scalars[index + 1]) }
                index += 2
                continue
            }
            if scalar == "#", index == 0 || commentStarters.contains(scalars[index - 1]) {
                // A comment runs to the end of its line; no continuation.
                while index < scalars.count, scalars[index] != "\n" {
                    out.append(scalars[index])
                    index += 1
                }
                continue
            }
            if scalar == "'" || scalar == "\"" {
                quote = scalar
                ansiC = scalar == "'" && index > 0 && scalars[index - 1] == "$"
            }
            out.append(scalar)
            index += 1
        }
        return String(out)
    }

    /// 1 for `\<LF>`, 2 for `\<CR><LF>`, nil otherwise.
    private static func continuationLength(_ scalars: [Unicode.Scalar], after index: Int) -> Int? {
        guard index + 1 < scalars.count else { return nil }
        if scalars[index + 1] == "\n" { return 1 }
        if scalars[index + 1] == "\r", index + 2 < scalars.count, scalars[index + 2] == "\n" { return 2 }
        return nil
    }

    private static let commentStarters: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", ";", "|", "&", "(", ")", "<", ">"]

    /// The line's top-level list elements: split at `;`, `&&`, `||`, a
    /// background `&` and newlines, outside quotes, escapes and groups.
    /// Each is one pipeline (or a group): pipes bind tighter than lists.
    /// A miscount only merges elements, which widens each reader's
    /// producers.
    static func listElements(_ line: String) -> [String] {
        let scalars = Array(line.unicodeScalars)
        var elements: [String] = []
        var current = String.UnicodeScalarView()
        var index = 0
        var quote: Unicode.Scalar?
        var depth = 0

        func flush() {
            let trimmed = String(current).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty == false { elements.append(trimmed) }
            current = String.UnicodeScalarView()
        }

        while index < scalars.count {
            let scalar = scalars[index]
            let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
            if let open = quote {
                current.append(scalar)
                if scalar == "\\", open != "'", let next {
                    current.append(next)
                    index += 2
                    continue
                }
                if scalar == open { quote = nil }
                index += 1
                continue
            }
            if scalar == "#", index == 0 || commentStarters.contains(scalars[index - 1]) {
                // A comment runs to the end of its line.
                while index < scalars.count, scalars[index] != "\n" {
                    current.append(scalars[index])
                    index += 1
                }
                continue
            }
            switch scalar {
            case "\\":
                current.append(scalar)
                if let next { current.append(next) }
                index += 2
                continue
            case "'", "\"", "`":
                quote = scalar
            case "(", "{":
                depth += 1
            case ")", "}":
                depth = max(0, depth - 1)
            default:
                if depth == 0, let width = listSeparatorWidth(scalars, at: index) {
                    flush()
                    index += width
                    continue
                }
            }
            current.append(scalar)
            index += 1
        }
        flush()
        return elements
    }

    private static func listSeparatorWidth(_ scalars: [Unicode.Scalar], at index: Int) -> Int? {
        let scalar = scalars[index]
        let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
        let previous: Unicode.Scalar? = index > 0 ? scalars[index - 1] : nil
        switch scalar {
        case ";", "\n", "\r":
            return 1
        case "&":
            if next == "&" { return 2 }
            // `&>`, `>&`, `<&`, `|&` are redirects or a pipe, not a list.
            if next == ">" || previous == ">" || previous == "<" || previous == "|" { return nil }
            return 1
        case "|":
            return next == "|" ? 2 : nil
        default:
            return nil
        }
    }

    /// The line re-points the shell's stdin (`exec < f`, `exec 0<&3`,
    /// `exec < <(…)`): a later reader with no pipe reads that.
    static func redirectsLineStdin(_ line: String) -> Bool {
        // Raw list elements: segment splitting drops an `exec` head.
        listElements(line).contains { element in
            let tokens = tokenizeCommand(element).filter { isAssignment($0.decoded) == false }
            guard let first = tokens.first, basename(first.decoded) == "exec" || first.decoded == "builtin"
                || first.decoded == "command"
            else { return false }
            return tokens.dropFirst().contains { token in
                token.wasQuoted == false && redirectOperator(token.decoded).hasPrefix("<")
            }
        }
    }

    /// The redirect operator part of a word: `0<&3` → `<&3`.
    static func redirectOperator(_ word: String) -> Substring {
        word.drop(while: { $0.isASCII && $0.isNumber })
    }

    // MARK: Readers

    /// Whether what `arguments`' command reads on stdin is readable: a
    /// literal here-string, a literal file (`< f`), a heredoc (its body
    /// lines are scanned as commands), else the pipeline's producers.
    static func stdinIsLiteral(_ arguments: [CommandToken], feed: StdinFeed) -> Bool {
        for (index, token) in arguments.enumerated() {
            let following = arguments.dropFirst(index + 1).first
            if token.decoded.hasPrefix("<<<") {
                let glued = token.decoded.dropFirst(3)
                if glued.isEmpty {
                    guard let content = following else { return false }
                    return content.wasAnsiC == false && isDynamic(content) == false
                }
                return token.wasAnsiC == false && glued.contains("$") == false && glued.contains("`") == false
            }
            guard token.wasQuoted == false else { continue }
            let operatorText = redirectOperator(token.decoded)
            if operatorText.hasPrefix("<(") || operatorText.hasPrefix("<&") { return false }
            if operatorText.hasPrefix("<<") { return true }
            guard operatorText.hasPrefix("<") else { continue }
            let glued = operatorText.drop(while: { $0 == "<" || $0 == ">" })
            if glued.isEmpty {
                guard let path = following else { return false }
                return isDynamic(path) == false && readsStdin(path.decoded) == false
                    || readsStdin(path.decoded) && feed.isLiteral
            }
            let path = String(glued)
            return path.contains("$") == false && path.contains("`") == false && readsStdin(path) == false
                || readsStdin(path) && feed.isLiteral
        }
        return feed.isLiteral
    }

    /// The command reads a heredoc (`<<EOF`, `<<-'EOF'`).
    static func readsHeredoc(_ arguments: [CommandToken]) -> Bool {
        arguments.contains { token in
            let operatorText = redirectOperator(token.decoded)
            return token.wasQuoted == false && operatorText.hasPrefix("<<") && operatorText.hasPrefix("<<<") == false
        }
    }

    // MARK: Producers

    /// A command rv can read the output of, or one that writes nothing a
    /// reader runs (`done`, `fi`, a bare literal assignment).
    static func isLiteralOrInert(_ tokens: [CommandToken]) -> Bool {
        if tokens.contains(where: { isDynamic($0) || $0.wasAnsiC || $0.decoded.hasPrefix("<(") || $0.decoded.hasPrefix(">(") }) {
            return false
        }
        switch commandStart(tokens) {
        case .none:
            return true
        case .opaque:
            return false
        case .at:
            return literalOutput(tokens) != nil
        }
    }

    /// What a literal producer emits: `echo` with no backslash, `printf`
    /// with no `%` and no escape but `\n`, `cat` of literal paths (its
    /// text is unread, so ""). nil for anything else, or a producer fed by
    /// a heredoc.
    static func literalOutput(_ rawTokens: [CommandToken]) -> String? {
        let tokens: [CommandToken]
        switch commandStart(rawTokens) {
        case .at(let index): tokens = Array(rawTokens[index...])
        case .none, .opaque: return nil
        }
        guard let head = tokens.first, readsHeredoc(tokens) == false,
              tokens.allSatisfy({ isDynamic($0) == false && $0.wasAnsiC == false })
        else { return nil }
        let arguments = droppingRedirects(Array(tokens.dropFirst()))
        switch basename(head.decoded) {
        case "echo":
            guard arguments.allSatisfy({ $0.decoded.contains("\\") == false }) else { return nil }
            let words = arguments.drop(while: { echoFlags.contains($0.decoded) })
            return words.map(\.decoded).joined(separator: " ")
        case "printf":
            let words = arguments.first?.decoded == "--" ? Array(arguments.dropFirst()) : arguments
            guard words.isEmpty == false, words.allSatisfy({ printfIsPlain($0.decoded) }) else { return nil }
            return words.map { $0.decoded.replacingOccurrences(of: "\\n", with: "\n") }.joined(separator: " ")
        case "cat":
            let files = arguments.filter { $0.decoded.hasPrefix("-") == false || $0.decoded == "-" }
            guard files.isEmpty == false, files.allSatisfy({ readsStdin($0.decoded) == false }) else { return nil }
            return ""
        default:
            return nil
        }
    }

    private static let echoFlags: Set<String> = ["-n", "-e", "-E", "-ne", "-en", "-nE", "-En"]

    /// No format directive and no escape but `\n`: the text printed is
    /// the text written.
    private static func printfIsPlain(_ text: String) -> Bool {
        text.contains("%") == false && text.replacingOccurrences(of: "\\n", with: "").contains("\\") == false
    }
}

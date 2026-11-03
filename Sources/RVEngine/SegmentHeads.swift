import Foundation

/// Words that introduce a command without being one: control-flow keywords
/// (`then rm -r ~`, `! rm -r ~`) and prefix builtins that run their operand
/// (`time -p rm -r ~`, `exec -- rm -r ~`, `coproc rm -r ~`). The real command
/// is the remainder.
private let leadingReservedWords: Set<String> = [
    "if", "then", "else", "elif", "while", "until", "do", "!",
    "time", "coproc", "exec", "builtin",
]

/// Prefix builtins whose own option words precede the command.
private let optionTakingHeads: Set<String> = ["time", "exec", "builtin"]

/// `exec` options that consume the following word.
private let execValueOptions: Set<String> = ["-a"]

private func isBlank(_ character: Character) -> Bool {
    character == " " || character == "\t"
}

/// Strips what precedes the executed command of one top-level piece:
/// reserved words (also when glued to a paren: `if(rm -r ~)`), function
/// definition heads, and `case` headers and arm patterns. Carries the
/// `case ... esac` nesting across the pieces of one split.
struct SegmentHeadState {
    private var caseDepth = 0

    /// The command text of `piece`, or nil when the piece is pure syntax
    /// (`case x in`, `esac`, a bare pattern list).
    mutating func strip(_ piece: String) -> String? {
        var current = stripLeadingReservedWords(piece)
        for _ in 0..<8 {
            let before = current
            if let rest = Self.caseBody(of: current) {
                caseDepth += 1
                guard rest.isEmpty == false else { return nil }
                current = stripLeadingReservedWords(rest)
            } else if current == "esac" {
                caseDepth = max(0, caseDepth - 1)
                return nil
            } else if caseDepth > 0, let rest = Self.afterArmPattern(current) {
                guard rest.isEmpty == false else { return nil }
                current = stripLeadingReservedWords(rest)
            } else if let rest = Self.afterFunctionHead(current) {
                current = stripLeadingReservedWords(rest)
            }
            if current == before { break }
        }
        return current
    }

    /// `case WORD in rest` becomes `rest`; nil when `text` is no case header.
    /// A header with no arm (`case x in`, or `case x in a` before a `|`)
    /// has no command, so a remainder without `)` is dropped.
    private static func caseBody(of text: String) -> String? {
        guard text.hasPrefix("case ") || text.hasPrefix("case\t") else { return nil }
        let pattern = #"^case\s+("[^"]*"|'[^']*'|\S+)\s+in\b\s*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let rest = String(text[range.upperBound...])
        return rest.contains(")") ? rest : ""
    }

    /// `pattern) cmd` or `(pattern) cmd` becomes `cmd`. Only called inside a
    /// `case`, where a pattern head cannot be a command.
    private static func afterArmPattern(_ text: String) -> String? {
        let pattern = #"^\(?(?:"[^"]*"|'[^']*'|[^\s()|;&<>"'])+\)\s*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range.upperBound...])
    }

    /// `name() body`, `name () body`, `function name body` become `body`.
    private static func afterFunctionHead(_ text: String) -> String? {
        let patterns = [
            #"^function\s+[^\s(){}]+(?:\s*\(\s*\))?\s*"#,
            #"^[^\s(){}=$"'`|&;<>]+\s*\(\s*\)\s*"#,
        ]
        for pattern in patterns {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let rest = String(text[range.upperBound...])
            if rest.isEmpty == false { return rest }
        }
        return nil
    }
}

func stripLeadingReservedWords(_ piece: String) -> String {
    var rest = Substring(piece).drop(while: isBlank)
    while true {
        let word = rest.prefix { isBlank($0) == false && $0 != "(" }
        guard leadingReservedWords.contains(String(word)) else { return String(rest) }
        var remainder = rest.dropFirst(word.count).drop(while: isBlank)
        if optionTakingHeads.contains(String(word)) {
            remainder = dropOptionWords(remainder, head: String(word))
        } else if word == "coproc" {
            remainder = dropCoprocName(remainder)
        }
        guard remainder.isEmpty == false else { return String(rest) }
        rest = remainder
    }
}

/// Drops `-p`-style option words (and `exec -a NAME`, `--`) after `time`,
/// `exec`, or `builtin`.
private func dropOptionWords(_ text: Substring, head: String) -> Substring {
    var rest = text
    while rest.first == "-" {
        let word = rest.prefix { isBlank($0) == false }
        rest = rest.dropFirst(word.count).drop(while: isBlank)
        if head == "exec", execValueOptions.contains(String(word)) {
            let value = rest.prefix { isBlank($0) == false }
            rest = rest.dropFirst(value.count).drop(while: isBlank)
        }
        if word == "--" { break }
    }
    return rest
}

/// `coproc NAME { ...; }` names the coprocess; the braces hold the command.
private func dropCoprocName(_ text: Substring) -> Substring {
    let name = text.prefix { isBlank($0) == false && $0 != "{" && $0 != "(" }
    let after = text.dropFirst(name.count).drop(while: isBlank)
    guard name.isEmpty == false, after.first == "{" || after.first == "(" else { return text }
    return after
}

/// True when an opening `(`/`{` that follows `prefix` (the segment text so
/// far) starts a command body rather than a literal mid-word character:
/// after only reserved words (`if(`, `then {`), a function head (`x() {`,
/// `function x {`), `coproc NAME`, or a `case` arm pattern (`x) (`).
func prefixIntroducesBody(_ prefix: String) -> Bool {
    var words = prefix.split(whereSeparator: isBlank).map(String.init)
    while let first = words.first, first != "coproc", leadingReservedWords.contains(first) {
        words.removeFirst()
    }
    guard let first = words.first, let last = words.last else { return true }
    if last.hasSuffix(")") { return true }
    if first == "function" { return words.count <= 2 }
    if first == "coproc" { return words.count <= 2 }
    return false
}

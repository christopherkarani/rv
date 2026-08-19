import Foundation

public enum Normalize {
    public static let maxWrapperIterations = 32

    public static func matchingView(of command: String) -> MatchingView {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return MatchingView("") }
        var current = applyRoleAwareQuotes(trimmed)
        var iteration = 0
        while iteration < maxWrapperIterations {
            iteration += 1
            if let stripped = stripSudo(current) {
                current = stripped
                continue
            }
            if let stripped = stripEnv(current) {
                current = stripped
                continue
            }
            if let stripped = stripCommandWrapper(current) {
                current = stripped
                continue
            }
            if let stripped = stripLeadingBackslash(current) {
                current = stripped
                continue
            }
            break
        }
        return MatchingView(stripAbsolutePathOnArgv0(current))
    }
}

struct CommandToken {
    var raw: String
    var decoded: String
    var wasQuoted: Bool
}

func tokenizeCommand(_ text: String) -> [CommandToken] {
    var tokens: [CommandToken] = []
    var index = text.startIndex

    while index < text.endIndex {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex else { break }

        var raw = ""
        var decoded = ""
        var wasQuoted = false

        while index < text.endIndex, !text[index].isWhitespace {
            let ch = text[index]
            if ch == "$",
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "("
            {
                let start = index
                index = text.index(after: text.index(after: index))
                var depth = 1
                while index < text.endIndex, depth > 0 {
                    if text[index] == "(" { depth += 1 }
                    if text[index] == ")" { depth -= 1 }
                    index = text.index(after: index)
                }
                let piece = String(text[start..<index])
                raw += piece
                decoded += piece
                continue
            }
            if ch == "`" {
                let start = index
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "`" {
                    index = text.index(after: index)
                }
                if index < text.endIndex {
                    index = text.index(after: index)
                }
                let piece = String(text[start..<index])
                raw += piece
                decoded += piece
                continue
            }
            if ch == "\"" || ch == "'" {
                wasQuoted = true
                raw.append(ch)
                index = text.index(after: index)
                let innerStart = index
                while index < text.endIndex, text[index] != ch {
                    index = text.index(after: index)
                }
                decoded += String(text[innerStart..<index])
                if index < text.endIndex {
                    raw.append(ch)
                    index = text.index(after: index)
                }
                continue
            }
            raw.append(ch)
            decoded.append(ch)
            index = text.index(after: index)
        }

        if !raw.isEmpty {
            tokens.append(CommandToken(raw: raw, decoded: decoded, wasQuoted: wasQuoted))
        }
    }
    return tokens
}

func applyRoleAwareQuotes(_ text: String) -> String {
    let tokens = tokenizeCommand(text)
    guard !tokens.isEmpty else { return text }
    var rendered: [String] = []
    var commandBase: String?
    var pendingDataFlag = false
    var wrapperSeek = WrapperSeek.none

    for token in tokens {
        let decoded = token.decoded
        if isShellSeparator(decoded) {
            rendered.append(decoded)
            commandBase = nil
            pendingDataFlag = false
            wrapperSeek = .none
            continue
        }

        if commandBase == nil {
            if let next = consumeWrapper(decoded: decoded, seek: &wrapperSeek) {
                if let command = next {
                    commandBase = command
                }
                rendered.append(decoded)
                continue
            }
            commandBase = basename(decoded)
            rendered.append(decoded)
            continue
        }

        if containsInlineCode(token) {
            rendered.append(decoded)
            pendingDataFlag = false
            continue
        }

        if let masked = maskAttachedDataValue(command: commandBase, token: token) {
            rendered.append(masked)
            pendingDataFlag = false
            continue
        }

        if decoded.hasPrefix("-") {
            if isDataConsumingFlag(command: commandBase, flag: decoded) {
                pendingDataFlag = true
            }
            rendered.append(decoded)
            continue
        }

        if token.wasQuoted, shouldMaskQuotedData(command: commandBase, pendingDataFlag: pendingDataFlag) {
            rendered.append(String(repeating: " ", count: max(decoded.count, 1)))
            pendingDataFlag = false
            continue
        }

        pendingDataFlag = false
        rendered.append(decoded)
    }
    return rendered.joined(separator: " ")
}

private enum WrapperSeek {
    case none
    case sudoFlags
    case envAssignments
    case commandOpt
}

/// Returns `nil` when `decoded` is the real argv0. Otherwise returns the command
/// basename if this token settles argv0 (e.g. `command -v`), or `.some(nil)` if
/// the token is still a wrapper/flag/assignment.
private func consumeWrapper(decoded: String, seek: inout WrapperSeek) -> String?? {
    switch seek {
    case .sudoFlags:
        if decoded == "--" {
            return .some(nil)
        }
        if decoded.hasPrefix("-"), !decoded.hasPrefix("--") {
            return .some(nil)
        }
        seek = .none
        return nil
    case .envAssignments:
        if decoded.contains("=") || decoded.hasPrefix("-") {
            return .some(nil)
        }
        seek = .none
        return nil
    case .commandOpt:
        if decoded == "-v" || decoded == "-V" {
            seek = .none
            return .some("command")
        }
        if decoded.hasPrefix("-") {
            return .some(nil)
        }
        seek = .none
        return nil
    case .none:
        switch basename(decoded) {
        case "sudo":
            seek = .sudoFlags
            return .some(nil)
        case "env":
            seek = .envAssignments
            return .some(nil)
        case "command":
            seek = .commandOpt
            return .some(nil)
        default:
            return nil
        }
    }
}

private func isShellSeparator(_ token: String) -> Bool {
    token == "&&" || token == "||" || token == ";" || token == "|"
}

private func containsInlineCode(_ token: CommandToken) -> Bool {
    token.decoded.contains("$(") || token.decoded.contains("`")
        || token.raw.contains("$(") || token.raw.contains("`")
}

private func isAllArgsData(_ command: String?) -> Bool {
    guard let command else { return false }
    return command == "echo" || command == "printf"
}

private func isSearchCommand(_ command: String?) -> Bool {
    guard let command else { return false }
    return command == "rg" || command == "grep"
}

private func isDataConsumingFlag(command: String?, flag: String) -> Bool {
    switch command {
    case "git":
        if flag == "--message" || flag.hasPrefix("--message=") { return true }
        if flag == "-m" { return true }
        return flag.hasPrefix("-") && !flag.hasPrefix("--") && flag.contains("m") && flag != "--"
    case "rg", "grep":
        return flag == "-e" || flag == "--regexp" || flag.hasPrefix("--regexp=")
    default:
        return false
    }
}

private func maskAttachedDataValue(command: String?, token: CommandToken) -> String? {
    let decoded = token.decoded
    guard let command else { return nil }
    if command == "git", decoded.hasPrefix("--message=") {
        let value = String(decoded.dropFirst("--message=".count))
        return "--message=" + String(repeating: " ", count: max(value.count, 1))
    }
    if command == "git", decoded.hasPrefix("-m"), decoded.count > 2, !decoded.hasPrefix("--") {
        let value = String(decoded.dropFirst(2))
        return "-m" + String(repeating: " ", count: max(value.count, 1))
    }
    return nil
}

private func shouldMaskQuotedData(command: String?, pendingDataFlag: Bool) -> Bool {
    isAllArgsData(command) || isSearchCommand(command) || pendingDataFlag
}

func firstWord(_ text: String) -> (word: String, rest: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let split = trimmed.firstIndex(where: { $0.isWhitespace }) else {
        return (trimmed, "")
    }
    let word = String(trimmed[..<split])
    let rest = trimmed[split...].trimmingCharacters(in: .whitespaces)
    return (word, rest)
}

func basename(_ token: String) -> String {
    if let slash = token.lastIndex(of: "/") {
        return String(token[token.index(after: slash)...])
    }
    return token
}

func stripSudo(_ text: String) -> String? {
    let (word, rest) = firstWord(text)
    guard basename(word) == "sudo" else { return nil }
    var remaining = rest
    while !remaining.isEmpty {
        let (option, after) = firstWord(remaining)
        guard option.hasPrefix("-") else { break }
        if option == "--" {
            remaining = after
            break
        }
        if option.hasPrefix("--") {
            return nil
        }
        remaining = after
    }
    return remaining.isEmpty ? nil : remaining
}

func stripEnv(_ text: String) -> String? {
    let (word, rest) = firstWord(text)
    guard basename(word) == "env" else { return nil }
    var remaining = rest
    while !remaining.isEmpty {
        let (option, after) = firstWord(remaining)
        if option.contains("=") {
            remaining = after
            continue
        }
        if option.hasPrefix("-") {
            remaining = after
            continue
        }
        break
    }
    return remaining.isEmpty ? nil : remaining
}

func stripCommandWrapper(_ text: String) -> String? {
    let (word, rest) = firstWord(text)
    guard basename(word) == "command" else { return nil }
    let (option, after) = firstWord(rest)
    if option == "-v" || option == "-V" {
        return nil
    }
    if option.hasPrefix("-") {
        return after.isEmpty ? nil : after
    }
    return rest.isEmpty ? nil : rest
}

func stripLeadingBackslash(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("\\") else { return nil }
    let rest = String(trimmed.dropFirst())
    let (word, _) = firstWord(rest)
    guard !word.isEmpty,
          word.unicodeScalars.allSatisfy({
              $0.properties.isAlphabetic || ("0"..."9").contains(Character($0))
                  || $0 == "_" || $0 == "-" || $0 == "."
          })
    else {
        return nil
    }
    return rest
}

func stripAbsolutePathOnArgv0(_ text: String) -> String {
    let (word, rest) = firstWord(text)
    guard looksLikeAbsoluteExecutable(word) else { return text }
    let base = basename(word)
    return rest.isEmpty ? base : "\(base) \(rest)"
}

private func looksLikeAbsoluteExecutable(_ word: String) -> Bool {
    guard word.contains("/") else { return false }
    if isRedirectToken(word) { return false }
    return word.hasPrefix("/") || word.hasPrefix("./") || word.hasPrefix("../")
}

private func isRedirectToken(_ word: String) -> Bool {
    if word.hasPrefix(">") || word.hasPrefix("<") || word.hasPrefix("&>") || word.hasPrefix(">&")
        || word.hasPrefix(":>")
    {
        return true
    }
    var index = word.startIndex
    while index < word.endIndex, word[index].isNumber {
        index = word.index(after: index)
    }
    return index > word.startIndex && index < word.endIndex && word[index] == ">"
}

func splitSegments(_ text: String) -> [String] {
    var segments: [String] = []
    var current = ""
    var index = text.startIndex
    var quote: Character?

    func flush() {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            segments.append(trimmed)
        }
        current = ""
    }

    while index < text.endIndex {
        let ch = text[index]
        if let currentQuote = quote {
            current.append(ch)
            if ch == currentQuote { quote = nil }
            index = text.index(after: index)
            continue
        }
        if ch == "'" || ch == "\"" {
            quote = ch
            current.append(ch)
            index = text.index(after: index)
            continue
        }
        if ch == "&",
           text.index(after: index) < text.endIndex,
           text[text.index(after: index)] == "&"
        {
            flush()
            index = text.index(after: text.index(after: index))
            continue
        }
        if ch == "|",
           text.index(after: index) < text.endIndex,
           text[text.index(after: index)] == "|"
        {
            flush()
            index = text.index(after: text.index(after: index))
            continue
        }
        if ch == ";" || ch == "|" {
            flush()
            index = text.index(after: index)
            continue
        }
        current.append(ch)
        index = text.index(after: index)
    }
    flush()
    return segments
}

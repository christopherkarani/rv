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
    var decoded: String
    var wasQuoted: Bool
}

func tokenizeCommand(_ text: String) -> [CommandToken] {
    var tokens: [CommandToken] = []
    let utf8 = text.utf8
    var index = utf8.startIndex

    while index < utf8.endIndex {
        while index < utf8.endIndex {
            let width = whitespaceLength(utf8, at: index)
            if width == 0 { break }
            index = utf8.index(index, offsetBy: width)
        }
        guard index < utf8.endIndex else { break }

        let tokenStart = index
        var decoded = ""
        var wasQuoted = false

        while index < utf8.endIndex, whitespaceLength(utf8, at: index) == 0 {
            let byte = utf8[index]
            if byte == UInt8(ascii: "$"),
               utf8.index(after: index) < utf8.endIndex,
               utf8[utf8.index(after: index)] == UInt8(ascii: "(")
            {
                let start = index
                index = utf8.index(after: utf8.index(after: index))
                var depth = 1
                while index < utf8.endIndex, depth > 0 {
                    let current = utf8[index]
                    if current == UInt8(ascii: "(") { depth += 1 }
                    else if current == UInt8(ascii: ")") { depth -= 1 }
                    utf8.formIndex(after: &index)
                }
                decoded.append(contentsOf: text[start..<index])
                continue
            }
            if byte == UInt8(ascii: "`") {
                let start = index
                utf8.formIndex(after: &index)
                while index < utf8.endIndex, utf8[index] != UInt8(ascii: "`") {
                    utf8.formIndex(after: &index)
                }
                if index < utf8.endIndex {
                    utf8.formIndex(after: &index)
                }
                decoded.append(contentsOf: text[start..<index])
                continue
            }
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                wasQuoted = true
                utf8.formIndex(after: &index)
                let innerStart = index
                while index < utf8.endIndex, utf8[index] != byte {
                    utf8.formIndex(after: &index)
                }
                decoded.append(contentsOf: text[innerStart..<index])
                if index < utf8.endIndex {
                    utf8.formIndex(after: &index)
                }
                continue
            }
            let runStart = index
            while index < utf8.endIndex, whitespaceLength(utf8, at: index) == 0 {
                let current = utf8[index]
                if current == UInt8(ascii: "`")
                    || current == UInt8(ascii: "\"")
                    || current == UInt8(ascii: "'")
                {
                    break
                }
                if current == UInt8(ascii: "$"),
                   utf8.index(after: index) < utf8.endIndex,
                   utf8[utf8.index(after: index)] == UInt8(ascii: "(")
                {
                    break
                }
                index = nextScalarIndex(utf8, index)
            }
            if index > runStart {
                decoded.append(contentsOf: text[runStart..<index])
            }
        }

        if index > tokenStart {
            tokens.append(CommandToken(decoded: decoded, wasQuoted: wasQuoted))
        }
    }
    return tokens
}

func applyRoleAwareQuotes(_ text: String) -> String {
    var tokens = tokenizeCommand(text)
    guard !tokens.isEmpty else { return text }
    var commandBase: String?
    var pendingDataFlag = false
    var wrapperSeek = WrapperSeek.none
    var pendingInterpreterPayload = false

    for index in tokens.indices {
        let token = tokens[index]
        let decoded = token.decoded

        if pendingInterpreterPayload {
            if token.wasQuoted, containsInlineCode(token) == false {
                tokens[index].decoded = " "
            }
            pendingInterpreterPayload = false
            pendingDataFlag = false
            continue
        }

        if isShellSeparator(decoded) {
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
                continue
            }
            commandBase = basename(decoded)
            continue
        }

        if let commandBase, isInterpreterExecutable(commandBase) {
            if isInterpreterProgramFlag(command: commandBase, flag: decoded) {
                pendingInterpreterPayload = true
                continue
            }
            if let masked = maskAttachedInterpreterProgram(command: commandBase, decoded: decoded),
               containsInlineCode(token) == false
            {
                tokens[index].decoded = masked
                continue
            }
        }

        if containsInlineCode(token) {
            pendingDataFlag = false
            continue
        }

        if let masked = maskAttachedDataValue(command: commandBase, token: token) {
            tokens[index].decoded = masked
            pendingDataFlag = false
            continue
        }

        if decoded.hasPrefix("-") {
            if isDataConsumingFlag(command: commandBase, flag: decoded) {
                pendingDataFlag = true
            }
            continue
        }

        if token.wasQuoted, shouldMaskQuotedData(command: commandBase, pendingDataFlag: pendingDataFlag) {
            tokens[index].decoded = String(repeating: " ", count: max(decoded.count, 1))
            pendingDataFlag = false
            continue
        }

        pendingDataFlag = false
    }
    return tokens.lazy.map(\.decoded).joined(separator: " ")
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
        let valueCount = decoded.dropFirst("--message=".count).count
        return "--message=" + String(repeating: " ", count: max(valueCount, 1))
    }
    if command == "git", decoded.hasPrefix("-m"), decoded.count > 2, !decoded.hasPrefix("--") {
        return "-m" + String(repeating: " ", count: max(decoded.count - 2, 1))
    }
    return nil
}

private func shouldMaskQuotedData(command: String?, pendingDataFlag: Bool) -> Bool {
    isAllArgsData(command) || isSearchCommand(command) || pendingDataFlag
}

func isInterpreterExecutable(_ head: String) -> Bool {
    let folded = head.lowercased()
    return isPythonExecutable(folded) || isNodeExecutable(folded) || isRubyExecutable(folded)
}

func isPythonExecutable(_ head: String) -> Bool {
    if head == "python" || head == "python2" || head == "python3" {
        return true
    }
    guard head.hasPrefix("python") else { return false }
    return head.dropFirst("python".count).allSatisfy { $0.isNumber || $0 == "." }
}

func isNodeExecutable(_ head: String) -> Bool {
    head == "node" || head == "nodejs"
}

func isRubyExecutable(_ head: String) -> Bool {
    if head == "ruby" { return true }
    guard head.hasPrefix("ruby") else { return false }
    return head.dropFirst("ruby".count).allSatisfy { $0.isNumber || $0 == "." }
}

private func isInterpreterProgramFlag(command: String?, flag: String) -> Bool {
    guard let command else { return false }
    let folded = command.lowercased()
    if isPythonExecutable(folded) {
        return flag == "-c"
    }
    if isNodeExecutable(folded) {
        return flag == "-e" || flag == "--eval" || flag == "-p" || flag == "--print"
    }
    if isRubyExecutable(folded) {
        return flag == "-e"
    }
    return false
}

private func maskAttachedInterpreterProgram(command: String?, decoded: String) -> String? {
    guard let command else { return nil }
    let folded = command.lowercased()
    if isRubyExecutable(folded), decoded.hasPrefix("-e"), decoded.count > 2, decoded.hasPrefix("--") == false {
        return "-e "
    }
    return nil
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
    let utf8 = text.utf8
    var index = utf8.startIndex
    var segmentStart = index
    var quote: UInt8?

    func flush(upTo end: String.Index) {
        let trimmed = text[segmentStart..<end].trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            segments.append(String(trimmed))
        }
    }

    while index < utf8.endIndex {
        let byte = utf8[index]
        if let currentQuote = quote {
            if byte == currentQuote { quote = nil }
            utf8.formIndex(after: &index)
            continue
        }
        if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\"") {
            quote = byte
            utf8.formIndex(after: &index)
            continue
        }
        if byte == UInt8(ascii: "&"),
           utf8.index(after: index) < utf8.endIndex,
           utf8[utf8.index(after: index)] == UInt8(ascii: "&")
        {
            flush(upTo: index)
            index = utf8.index(after: utf8.index(after: index))
            segmentStart = index
            continue
        }
        if byte == UInt8(ascii: "|"),
           utf8.index(after: index) < utf8.endIndex,
           utf8[utf8.index(after: index)] == UInt8(ascii: "|")
        {
            flush(upTo: index)
            index = utf8.index(after: utf8.index(after: index))
            segmentStart = index
            continue
        }
        if byte == UInt8(ascii: ";") || byte == UInt8(ascii: "|") {
            flush(upTo: index)
            utf8.formIndex(after: &index)
            segmentStart = index
            continue
        }
        index = nextScalarIndex(utf8, index)
    }
    flush(upTo: utf8.endIndex)
    return segments
}

private func whitespaceLength(_ utf8: String.UTF8View, at index: String.Index) -> Int {
    let byte = utf8[index]
    if byte < 0x80 {
        switch byte {
        case 9, 10, 11, 12, 13, 32:
            return 1
        default:
            return 0
        }
    }
    guard let (scalar, width) = decodeScalar(utf8, at: index) else { return 0 }
    return Character(scalar).isWhitespace ? width : 0
}

private func nextScalarIndex(_ utf8: String.UTF8View, _ index: String.Index) -> String.Index {
    if utf8[index] < 0x80 {
        return utf8.index(after: index)
    }
    guard let (_, width) = decodeScalar(utf8, at: index) else {
        return utf8.index(after: index)
    }
    return utf8.index(index, offsetBy: width, limitedBy: utf8.endIndex) ?? utf8.endIndex
}

private func decodeScalar(
    _ utf8: String.UTF8View,
    at index: String.Index
) -> (Unicode.Scalar, Int)? {
    var iterator = utf8[index...].makeIterator()
    var decoder = UTF8()
    switch decoder.decode(&iterator) {
    case .scalarValue(let scalar):
        return (scalar, utf8Width(scalar))
    case .emptyInput, .error:
        return nil
    }
}

private func utf8Width(_ scalar: Unicode.Scalar) -> Int {
    switch scalar.value {
    case 0..<0x80:
        return 1
    case 0x80..<0x800:
        return 2
    case 0x800..<0x1_0000:
        return 3
    default:
        return 4
    }
}

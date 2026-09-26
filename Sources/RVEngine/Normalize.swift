import Foundation
import RVDomain

public enum Normalize {
    public static let maxWrapperIterations = 32

    public static func matchingView(of command: String) -> MatchingView {
        CommandPeelCore.matchingView(of: command)
    }

    /// Returns the matching view of `command`.
    public static func matchingView(of command: ShellCommand) -> MatchingView {
        matchingView(of: command.rawValue)
    }
}

struct CommandToken {
    var decoded: String
    var wasQuoted: Bool
    var wasAnsiC: Bool = false
}

func tokenizeCommand(_ text: String) -> [CommandToken] {
    var tokens: [CommandToken] = []
    let utf8 = text.utf8
    var index = utf8.startIndex

    while index < utf8.endIndex {
        var emittedNewline = false
        while index < utf8.endIndex {
            if let width = newlineWidth(utf8, at: index) {
                if emittedNewline == false {
                    tokens.append(CommandToken(decoded: "\n", wasQuoted: false))
                    emittedNewline = true
                }
                index = utf8.index(index, offsetBy: width)
                continue
            }
            let width = whitespaceLength(utf8, at: index)
            if width == 0 { break }
            index = utf8.index(index, offsetBy: width)
        }
        guard index < utf8.endIndex else { break }

        let tokenStart = index
        var decoded = ""
        var wasQuoted = false
        var wasAnsiC = false

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
            if byte == UInt8(ascii: "$"),
               utf8.index(after: index) < utf8.endIndex,
               utf8[utf8.index(after: index)] == UInt8(ascii: "'")
            {
                wasQuoted = true
                wasAnsiC = true
                utf8.formIndex(after: &index)
                utf8.formIndex(after: &index)
                let innerStart = index
                while index < utf8.endIndex, utf8[index] != UInt8(ascii: "'") {
                    utf8.formIndex(after: &index)
                }
                decoded.append("$")
                decoded.append(contentsOf: text[innerStart..<index])
                if index < utf8.endIndex {
                    utf8.formIndex(after: &index)
                }
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
                   utf8.index(after: index) < utf8.endIndex
                {
                    let next = utf8[utf8.index(after: index)]
                    if next == UInt8(ascii: "(") || next == UInt8(ascii: "'") {
                        break
                    }
                }
                index = nextScalarIndex(utf8, index)
            }
            if index > runStart {
                decoded.append(contentsOf: text[runStart..<index])
            }
        }

        if index > tokenStart {
            tokens.append(CommandToken(decoded: decoded, wasQuoted: wasQuoted, wasAnsiC: wasAnsiC))
        }
    }
    return tokens
}

func applyRoleAwareQuotes(_ text: String) -> String {
    var tokens = tokenizeCommand(text)
    guard !tokens.isEmpty else { return text }
    var commandBase: String?
    var gitSubcommand: String?
    var pendingGitGlobalArg = false
    var pendingDataFlag = false
    var gitGrepPatternPending = false
    var gitConfigValuePending = false
    var pendingGitConfigArg = false
    var wrapperSeek = WrapperSeek.none
    var pendingInterpreterPayload = false
    let unquotedDataMaskSafe = tokens.contains { tokenHasShellMeta($0.decoded) } == false

    for index in tokens.indices {
        if tokens[index].wasAnsiC,
           let surfaced = surfacedAnsiC(
               tokens[index],
               commandBase: commandBase,
               gitSubcommand: gitSubcommand,
               pendingDataFlag: pendingDataFlag,
               gitGrepPatternPending: gitGrepPatternPending,
               pendingInterpreterPayload: pendingInterpreterPayload,
               isOnlyToken: tokens.count == 1
           )
        {
            tokens[index].decoded = surfaced
        }
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
            gitSubcommand = nil
            pendingGitGlobalArg = false
            pendingDataFlag = false
            gitGrepPatternPending = false
            gitConfigValuePending = false
            pendingGitConfigArg = false
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

        if commandBase == "git", gitSubcommand == nil {
            if pendingGitGlobalArg {
                pendingGitGlobalArg = false
                continue
            }
            if isGitGlobalValueFlag(decoded) {
                pendingGitGlobalArg = true
                continue
            }
            if isGitGlobalAttachedFlag(decoded) {
                continue
            }
            if decoded.hasPrefix("-") == false {
                gitSubcommand = decoded
                gitGrepPatternPending = decoded == "grep"
                gitConfigValuePending = false
                continue
            }
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

        if let masked = maskAttachedDataValue(
            command: commandBase,
            gitSubcommand: gitSubcommand,
            token: token
        ) {
            tokens[index].decoded = masked
            pendingDataFlag = false
            continue
        }

        if decoded.hasPrefix("-") {
            if gitSubcommand == "grep", decoded == "--" || isGitGrepPatternFileFlag(decoded) {
                gitGrepPatternPending = false
                continue
            }
            if gitSubcommand == "config", isGitConfigValueFlag(decoded) {
                pendingGitConfigArg = true
                continue
            }
            if isDataConsumingFlag(
                command: commandBase,
                gitSubcommand: gitSubcommand,
                flag: decoded
            ) {
                pendingDataFlag = true
                if gitSubcommand == "grep" {
                    gitGrepPatternPending = false
                }
            }
            continue
        }

        if pendingGitConfigArg {
            pendingGitConfigArg = false
            continue
        }

        if gitSubcommand == "config" {
            if containsInlineCode(token) == false, let masked = maskGitConfigAssignment(decoded) {
                tokens[index].decoded = masked
                gitConfigValuePending = false
                pendingDataFlag = false
                continue
            }
            if gitConfigValuePending, containsInlineCode(token) == false {
                tokens[index].decoded = String(repeating: " ", count: max(decoded.count, 1))
                gitConfigValuePending = false
                pendingDataFlag = false
                continue
            }
            gitConfigValuePending = true
            pendingDataFlag = false
            continue
        }

        if unquotedDataMaskSafe,
           isAllArgsData(commandBase),
           containsInlineCode(token) == false
        {
            tokens[index].decoded = String(repeating: " ", count: max(decoded.count, 1))
            pendingDataFlag = false
            gitGrepPatternPending = false
            continue
        }

        if token.wasQuoted,
           shouldMaskQuotedData(
               command: commandBase,
               gitSubcommand: gitSubcommand,
               pendingDataFlag: pendingDataFlag,
               gitGrepPatternPending: gitGrepPatternPending
           )
        {
            tokens[index].decoded = String(repeating: " ", count: max(decoded.count, 1))
            pendingDataFlag = false
            gitGrepPatternPending = false
            continue
        }

        pendingDataFlag = false
        gitGrepPatternPending = false
    }
    return joinDecodedTokens(tokens)
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
    token == "&&" || token == "||" || token == ";" || token == "|" || token == "\n"
}

private func containsInlineCode(_ token: CommandToken) -> Bool {
    token.decoded.contains("$(") || token.decoded.contains("`")
}

/// Tokenizer is whitespace-only, so `echo ok; git reset --hard` is one
/// `ok;` token. Unquoted echo/tldr masking must not run on a line that
/// still has glued `;` / redirect / pipe metacharacters.
private func tokenHasShellMeta(_ decoded: String) -> Bool {
    decoded.contains(where: { ";|&<>()".contains($0) })
}

/// Matching-view surface for `$''` tokens. Tokenizer keeps `$` in `decoded` so
/// unwrap of `bash -c $'…'` stays limited.
private func surfacedAnsiC(
    _ token: CommandToken,
    commandBase: String?,
    gitSubcommand: String?,
    pendingDataFlag: Bool,
    gitGrepPatternPending: Bool,
    pendingInterpreterPayload: Bool,
    isOnlyToken: Bool
) -> String? {
    guard token.wasAnsiC, let dollar = token.decoded.lastIndex(of: "$") else { return nil }
    let prefix = String(token.decoded[..<dollar])
    let inner = String(token.decoded[token.decoded.index(after: dollar)...])
    let candidate = prefix + decodeAnsiCEscapes(inner)
    if pendingInterpreterPayload { return nil }
    if shouldMaskQuotedData(
        command: commandBase,
        gitSubcommand: gitSubcommand,
        pendingDataFlag: pendingDataFlag,
        gitGrepPatternPending: gitGrepPatternPending
    ) {
        return nil
    }
    if commandBase == nil {
        if isOnlyToken { return candidate }
        if candidate.contains(where: { $0.isWhitespace }) { return nil }
        return candidate
    }
    if candidate.hasPrefix("-"), candidate.contains(where: { $0.isWhitespace }) == false {
        return candidate
    }
    return nil
}

private func decodeAnsiCEscapes(_ inner: String) -> String {
    var result = ""
    var index = inner.startIndex
    while index < inner.endIndex {
        let character = inner[index]
        if character != "\\" {
            result.append(character)
            index = inner.index(after: index)
            continue
        }
        let next = inner.index(after: index)
        guard next < inner.endIndex else {
            result.append("\\")
            break
        }
        let escape = inner[next]
        switch escape {
        case "a":
            result.append("\u{7}")
            index = inner.index(after: next)
        case "b":
            result.append("\u{8}")
            index = inner.index(after: next)
        case "e", "E":
            result.append("\u{1B}")
            index = inner.index(after: next)
        case "f":
            result.append("\u{C}")
            index = inner.index(after: next)
        case "n":
            result.append("\n")
            index = inner.index(after: next)
        case "r":
            result.append("\r")
            index = inner.index(after: next)
        case "t":
            result.append("\t")
            index = inner.index(after: next)
        case "v":
            result.append("\u{B}")
            index = inner.index(after: next)
        case "\\", "'", "\"", "?":
            result.append(escape)
            index = inner.index(after: next)
        case "x":
            var hex = ""
            var cursor = inner.index(after: next)
            while hex.count < 2, cursor < inner.endIndex, inner[cursor].isHexDigit {
                hex.append(inner[cursor])
                cursor = inner.index(after: cursor)
            }
            if hex.isEmpty {
                result.append("x")
                index = inner.index(after: next)
            } else if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
                index = cursor
            } else {
                index = cursor
            }
        case "0"..."7":
            var octal = String(escape)
            var cursor = inner.index(after: next)
            while octal.count < 3, cursor < inner.endIndex {
                let digit = inner[cursor]
                guard digit >= "0", digit <= "7" else { break }
                octal.append(digit)
                cursor = inner.index(after: cursor)
            }
            if let value = UInt32(octal, radix: 8), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            }
            index = cursor
        default:
            result.append(escape)
            index = inner.index(after: next)
        }
    }
    return result
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

private func joinDecodedTokens(_ tokens: [CommandToken]) -> String {
    var out = ""
    var lastWasNewline = true
    for token in tokens {
        if token.decoded == "\n" {
            out.append("\n")
            lastWasNewline = true
            continue
        }
        if lastWasNewline == false {
            out.append(" ")
        }
        out.append(token.decoded)
        lastWasNewline = false
    }
    return out
}

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
    let legacy = tokenizeCommand(text)
    guard !legacy.isEmpty else { return text }
    return applyRoleAwareQuotes(tokens: legacy.map {
        Token(lexeme: $0.decoded, wasQuoted: $0.wasQuoted, wasAnsiC: $0.wasAnsiC)
    })
}

/// Role-aware masking over pipeline tokens. The `String` overload maps the
/// legacy tokenizer output here 1:1; the facade passes `ShellPipeline.tokenize`.
func applyRoleAwareQuotes(tokens: [Token]) -> String {
    var tokens = tokens
    guard !tokens.isEmpty else { return "" }
    var commandBase: String?
    var gitSubcommand: String?
    var pendingGitGlobalArg = false
    var pendingDataFlag = false
    var gitGrepPatternPending = false
    var gitConfigValuePending = false
    var pendingGitConfigArg = false
    var wrapperSeek = WrapperSeek.none
    var pendingInterpreterPayload = false
    let unquotedDataMaskSafe = tokens.contains { tokenHasShellMeta($0.lexeme) } == false

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
            tokens[index].lexeme = surfaced
        }
        let token = tokens[index]
        let decoded = token.lexeme

        if pendingInterpreterPayload {
            if token.wasQuoted, containsInlineCode(token) == false {
                tokens[index].lexeme = " "
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
                tokens[index].lexeme = masked
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
            tokens[index].lexeme = masked
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
                tokens[index].lexeme = masked
                gitConfigValuePending = false
                pendingDataFlag = false
                continue
            }
            if gitConfigValuePending, containsInlineCode(token) == false {
                tokens[index].lexeme = String(repeating: " ", count: max(decoded.count, 1))
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
            tokens[index].lexeme = String(repeating: " ", count: max(decoded.count, 1))
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
            tokens[index].lexeme = String(repeating: " ", count: max(decoded.count, 1))
            pendingDataFlag = false
            gitGrepPatternPending = false
            continue
        }

        pendingDataFlag = false
        gitGrepPatternPending = false
    }
    return joinTokenLexemes(tokens)
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

private func containsInlineCode(_ token: Token) -> Bool {
    token.lexeme.contains("$(") || token.lexeme.contains("`")
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
    _ token: Token,
    commandBase: String?,
    gitSubcommand: String?,
    pendingDataFlag: Bool,
    gitGrepPatternPending: Bool,
    pendingInterpreterPayload: Bool,
    isOnlyToken: Bool
) -> String? {
    guard token.wasAnsiC, let dollar = token.lexeme.lastIndex(of: "$") else { return nil }
    let prefix = String(token.lexeme[..<dollar])
    let inner = String(token.lexeme[token.lexeme.index(after: dollar)...])
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

private func isAllArgsData(_ command: String?) -> Bool {
    guard let command else { return false }
    switch command {
    case "echo", "printf", "man", "tldr", "whatis", "apropos", "awk", "sed", "jq":
        return true
    default:
        return false
    }
}

private func isSearchCommand(_ command: String?) -> Bool {
    guard let command else { return false }
    switch command {
    case "rg", "grep", "fgrep", "egrep", "ag", "ack", "ripgrep":
        return true
    default:
        return false
    }
}

private func isGitGlobalValueFlag(_ flag: String) -> Bool {
    flag == "-C" || flag == "-c"
        || flag == "--git-dir" || flag == "--work-tree"
        || flag == "--namespace" || flag == "--config-env"
}

private func isGitGlobalAttachedFlag(_ flag: String) -> Bool {
    flag.hasPrefix("--git-dir=") || flag.hasPrefix("--work-tree=")
        || flag.hasPrefix("--namespace=") || flag.hasPrefix("--config-env=")
}

private func isGitSearchSubcommand(_ subcommand: String?) -> Bool {
    switch subcommand {
    case "log", "show", "diff", "whatchanged", "rev-list":
        return true
    default:
        return false
    }
}

private func isDataConsumingFlag(command: String?, gitSubcommand: String?, flag: String) -> Bool {
    switch command {
    case "git":
        if flag == "--message" || flag.hasPrefix("--message=") { return true }
        if flag == "-m" { return true }
        if flag == "--grep" || flag.hasPrefix("--grep=") { return true }
        if flag == "--grep-reflog" || flag.hasPrefix("--grep-reflog=") { return true }
        if gitSubcommand == "grep" {
            return flag == "-e" || flag == "--regexp" || flag.hasPrefix("--regexp=")
        }
        if isGitSearchSubcommand(gitSubcommand) {
            if flag == "-S" || flag == "-G" { return true }
        }
        if isGitPrettyFormatFlag(flag) { return true }
        if flag == "--trailer" || flag.hasPrefix("--trailer=") { return true }
        return flag.hasPrefix("-") && !flag.hasPrefix("--") && flag.contains("m") && flag != "--"
    case "rg", "grep", "fgrep", "egrep", "ag", "ack", "ripgrep":
        return flag == "-e" || flag == "--regexp" || flag.hasPrefix("--regexp=")
    case "gh":
        return flag == "--title" || flag.hasPrefix("--title=")
            || flag == "--body" || flag.hasPrefix("--body=")
    case "find":
        return flag == "-name" || flag == "-iname"
            || flag == "-path" || flag == "-ipath"
            || flag == "-wholename" || flag == "-iwholename"
            || flag == "-regex" || flag == "-iregex"
            || flag == "-lname"
    default:
        return false
    }
}

private func maskAttachedDataValue(
    command: String?,
    gitSubcommand: String?,
    token: Token
) -> String? {
    let decoded = token.lexeme
    guard let command else { return nil }
    if command == "git", decoded.hasPrefix("--message=") {
        let valueCount = decoded.dropFirst("--message=".count).count
        return "--message=" + String(repeating: " ", count: max(valueCount, 1))
    }
    if command == "git", decoded.hasPrefix("--grep-reflog=") {
        let valueCount = decoded.dropFirst("--grep-reflog=".count).count
        return "--grep-reflog=" + String(repeating: " ", count: max(valueCount, 1))
    }
    if command == "git", decoded.hasPrefix("--grep=") {
        let valueCount = decoded.dropFirst("--grep=".count).count
        return "--grep=" + String(repeating: " ", count: max(valueCount, 1))
    }
    if command == "git", decoded.hasPrefix("--pretty=") {
        let valueCount = decoded.dropFirst("--pretty=".count).count
        return "--pretty=" + String(repeating: " ", count: max(valueCount, 1))
    }
    if command == "git", decoded.hasPrefix("--format=") {
        let valueCount = decoded.dropFirst("--format=".count).count
        return "--format=" + String(repeating: " ", count: max(valueCount, 1))
    }
    if command == "git", decoded.hasPrefix("--trailer=") {
        let valueCount = decoded.dropFirst("--trailer=".count).count
        return "--trailer=" + String(repeating: " ", count: max(valueCount, 1))
    }
    if command == "git", isGitSearchSubcommand(gitSubcommand) {
        if decoded.hasPrefix("-S"), decoded.count > 2, decoded.hasPrefix("--") == false {
            return "-S" + String(repeating: " ", count: max(decoded.count - 2, 1))
        }
        if decoded.hasPrefix("-G"), decoded.count > 2, decoded.hasPrefix("--") == false {
            return "-G" + String(repeating: " ", count: max(decoded.count - 2, 1))
        }
    }
    if command == "git", decoded.hasPrefix("-m"), decoded.count > 2, !decoded.hasPrefix("--") {
        return "-m" + String(repeating: " ", count: max(decoded.count - 2, 1))
    }
    if command == "gh" {
        if decoded.hasPrefix("--title=") {
            let valueCount = decoded.dropFirst("--title=".count).count
            return "--title=" + String(repeating: " ", count: max(valueCount, 1))
        }
        if decoded.hasPrefix("--body=") {
            let valueCount = decoded.dropFirst("--body=".count).count
            return "--body=" + String(repeating: " ", count: max(valueCount, 1))
        }
    }
    return nil
}

private func isGitGrepPatternFileFlag(_ flag: String) -> Bool {
    flag == "-f" || flag == "--file" || flag.hasPrefix("--file=")
}

private func shouldMaskQuotedData(
    command: String?,
    gitSubcommand: String?,
    pendingDataFlag: Bool,
    gitGrepPatternPending: Bool
) -> Bool {
    isAllArgsData(command)
        || isSearchCommand(command)
        || pendingDataFlag
        || (gitSubcommand == "grep" && gitGrepPatternPending)
}

private func isGitPrettyFormatFlag(_ flag: String) -> Bool {
    flag == "--pretty" || flag.hasPrefix("--pretty=")
        || flag == "--format" || flag.hasPrefix("--format=")
}

private func isGitConfigValueFlag(_ flag: String) -> Bool {
    flag == "--file" || flag.hasPrefix("--file=")
        || flag == "-f"
        || flag == "--blob" || flag.hasPrefix("--blob=")
        || flag == "--default" || flag.hasPrefix("--default=")
        || flag == "--type" || flag.hasPrefix("--type=")
}

private func maskGitConfigAssignment(_ decoded: String) -> String? {
    guard let equals = decoded.firstIndex(of: "=") else { return nil }
    let prefix = String(decoded[...equals])
    let valueCount = decoded.distance(from: decoded.index(after: equals), to: decoded.endIndex)
    return prefix + String(repeating: " ", count: max(valueCount, 1))
}

func isInterpreterExecutable(_ head: String) -> Bool {
    let folded = head.lowercased()
    return isPythonExecutable(folded)
        || isNodeExecutable(folded)
        || isRubyExecutable(folded)
        || isPerlExecutable(folded)
        || isPHPExecutable(folded)
        || isLuaExecutable(folded)
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

func isPerlExecutable(_ head: String) -> Bool {
    if head == "perl" { return true }
    guard head.hasPrefix("perl") else { return false }
    return head.dropFirst("perl".count).allSatisfy { $0.isNumber || $0 == "." }
}

func isPHPExecutable(_ head: String) -> Bool {
    if head == "php" { return true }
    guard head.hasPrefix("php") else { return false }
    return head.dropFirst("php".count).allSatisfy { $0.isNumber || $0 == "." }
}

func isLuaExecutable(_ head: String) -> Bool {
    if head == "lua" || head == "luajit" { return true }
    guard head.hasPrefix("lua") else { return false }
    return head.dropFirst("lua".count).allSatisfy { $0.isNumber || $0 == "." }
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
    if isRubyExecutable(folded) || isLuaExecutable(folded) {
        return flag == "-e"
    }
    if isPerlExecutable(folded) {
        if flag == "-e" || flag == "-E" { return true }
        return flag.hasPrefix("-") && flag.hasPrefix("--") == false && flag.contains("e")
    }
    if isPHPExecutable(folded) {
        return flag == "-r"
    }
    return false
}

private func maskAttachedInterpreterProgram(command: String?, decoded: String) -> String? {
    guard let command else { return nil }
    let folded = command.lowercased()
    if isRubyExecutable(folded) || isLuaExecutable(folded) || isPerlExecutable(folded),
       decoded.hasPrefix("-e"), decoded.count > 2, decoded.hasPrefix("--") == false
    {
        return "-e "
    }
    if isPerlExecutable(folded), decoded.hasPrefix("-E"), decoded.count > 2 {
        return "-E "
    }
    if isPHPExecutable(folded), decoded.hasPrefix("-r"), decoded.count > 2, decoded.hasPrefix("--") == false {
        return "-r "
    }
    return nil
}

/// File-write / print heredocs are data. Executing sinks keep the body so
/// `cat <<EOF | bash` stays a pin true-positive.
func maskNonExecutingHeredocBodies(_ text: String) -> String {
    guard let heredoc = extractHeredoc(text), heredoc.body.isEmpty == false else {
        return text
    }
    if peelExecutingSink(text, workingDirectory: nil) != nil {
        return text
    }
    guard let range = text.range(of: heredoc.body) else {
        return text
    }
    return text.replacingCharacters(
        in: range,
        with: String(repeating: " ", count: heredoc.body.count)
    )
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
        if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
            flush(upTo: index)
            utf8.formIndex(after: &index)
            if byte == UInt8(ascii: "\r"),
               index < utf8.endIndex,
               utf8[index] == UInt8(ascii: "\n")
            {
                utf8.formIndex(after: &index)
            }
            segmentStart = index
            continue
        }
        index = nextScalarIndex(utf8, index)
    }
    flush(upTo: utf8.endIndex)
    return segments
}

private func joinTokenLexemes(_ tokens: [Token]) -> String {
    var out = ""
    var lastWasNewline = true
    for token in tokens {
        if token.lexeme == "\n" {
            out.append("\n")
            lastWasNewline = true
            continue
        }
        if lastWasNewline == false {
            out.append(" ")
        }
        out.append(token.lexeme)
        lastWasNewline = false
    }
    return out
}

/// Unquoted `\n` / `\r\n` / `\r` width. Quoted newlines stay inside the token.
private func newlineWidth(_ utf8: String.UTF8View, at index: String.Index) -> Int? {
    guard index < utf8.endIndex else { return nil }
    let byte = utf8[index]
    if byte == UInt8(ascii: "\n") { return 1 }
    if byte == UInt8(ascii: "\r") {
        let next = utf8.index(after: index)
        if next < utf8.endIndex, utf8[next] == UInt8(ascii: "\n") {
            return 2
        }
        return 1
    }
    return nil
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

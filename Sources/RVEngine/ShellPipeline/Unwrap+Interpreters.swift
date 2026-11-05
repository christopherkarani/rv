import Foundation
import RVDomain

// Part of the single recursive unwrap; see `Unwrap.swift` for the
// recursion, budget, and `peelAfterSink` dispatch.

// MARK: - Shells (`sh -c` / `bash -c` / `zsh -c`)

func shellKind(_ head: String) -> WrapperKind? {
    switch head {
    case "bash":
        return .bash
    case "sh":
        return .sh
    case "zsh":
        return .zsh
    default:
        return nil
    }
}

func peelShell(
    _ tokens: [ShellPipeline.Token],
    kind: WrapperKind,
    workingDirectory: WorkingDirectory?
) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            return .notWrapper
        }
        if token == "-c" || token == "--command" {
            guard index + 1 < tokens.count else { return .limited(kind) }
            return peelShellPayload(tokens[index + 1], kind: kind, cwd: workingDirectory)
        }
        if let value = attachedOptionValue(token, long: "--command") {
            return peelShellPayload(
                ShellPipeline.Token(lexeme: value, wasQuoted: tokens[index].wasQuoted),
                kind: kind,
                cwd: workingDirectory
            )
        }
        if token == "-o" || token == "-O" {
            guard index + 1 < tokens.count else { return .limited(kind) }
            index += 2
            continue
        }
        if token.hasPrefix("--") {
            index += 1
            continue
        }
        if token.hasPrefix("-"), token.contains("c") {
            guard index + 1 < tokens.count else { return .limited(kind) }
            return peelShellPayload(tokens[index + 1], kind: kind, cwd: workingDirectory)
        }
        if token.hasPrefix("-") {
            index += 1
            continue
        }
        return .notWrapper
    }
    return .notWrapper
}

/// Unquoted, `$`, and `$'…'` `-c` payloads are uncertain. Fail-closed.
func peelShellPayload(
    _ token: ShellPipeline.Token,
    kind: WrapperKind,
    cwd: WorkingDirectory?
) -> Peel {
    if token.wasQuoted == false {
        return .limited(kind)
    }
    if token.lexeme.contains("$") || token.lexeme.contains("`") {
        return .limited(kind)
    }
    return .next(token.lexeme, kind, cwd)
}

// MARK: - Interpreters (python / node / ruby)

func peelInterpreter(
    _ tokens: [ShellPipeline.Token],
    kind: WrapperKind,
    flags: Set<String>,
    extract: (String) -> InterpreterExtract,
    workingDirectory: WorkingDirectory?
) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].lexeme
        if flags.contains(token) {
            guard index + 1 < tokens.count else { return .limited(kind) }
            return peelCapturedInterpreterPayload(
                tokens[index + 1],
                kind: kind,
                extract: extract,
                cwd: workingDirectory
            )
        }
        if kind == .ruby, token.hasPrefix("-e"), token.count > 2 {
            // Same gate as a separate `-e` payload: expanding text is unknown.
            if tokens[index].wasQuoted == false || token.contains("$") || token.contains("`") {
                return .limited(kind)
            }
            return interpreterPeel(
                extract(String(token.dropFirst(2))),
                kind: kind,
                cwd: workingDirectory
            )
        }
        if token == "-W" || token == "-X" || token == "--check-hash-based-pycs"
            || token == "-r" || token == "-I" || token == "-C" || token == "--title"
        {
            guard index + 1 < tokens.count else { return .limited(kind) }
            index += 2
            continue
        }
        if token.hasPrefix("-") {
            index += 1
            continue
        }
        return .notWrapper
    }
    return .notWrapper
}

/// Quoted `-c`/`-e` with no `$` / backtick is a captured program. Unquoted
/// or expanding payloads are an unknown inner program (never-slip).
private func peelCapturedInterpreterPayload(
    _ payload: ShellPipeline.Token,
    kind: WrapperKind,
    extract: (String) -> InterpreterExtract,
    cwd: WorkingDirectory?
) -> Peel {
    if payload.wasQuoted == false {
        return .limited(kind)
    }
    if payload.lexeme.contains("$") {
        return .limited(kind)
    }
    return interpreterPeel(extract(payload.lexeme), kind: kind, cwd: cwd)
}

private func interpreterPeel(
    _ extract: InterpreterExtract,
    kind: WrapperKind,
    cwd: WorkingDirectory?
) -> Peel {
    switch extract {
    case .command(let inner):
        return .next(inner, kind, cwd)
    case .dataOnly:
        return .notWrapper
    case .limited:
        return .limited(kind)
    }
}

enum InterpreterExtract: Sendable, Equatable {
    case command(String)
    case dataOnly
    case limited
}

/// `code` with the first call matching `pattern` removed (name through its
/// balanced closing paren, or a backtick span). Nil when the call cannot be
/// delimited, so the caller fails closed.
private func removingFirstCall(_ code: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
        let range = Range(match.range, in: code)
    else { return nil }
    if code[range].hasPrefix("`") {
        return code.replacingCharacters(in: range, with: " ")
    }
    var depth = 1
    var quote: Character?
    var index = range.upperBound
    while index < code.endIndex {
        let char = code[index]
        if let open = quote {
            if char == "\\" {
                index = code.index(after: index)
                if index == code.endIndex { return nil }
            } else if char == open {
                quote = nil
            }
        } else if char == "'" || char == "\"" {
            quote = char
        } else if char == "(" {
            depth += 1
        } else if char == ")" {
            depth -= 1
            if depth == 0 {
                return code.replacingCharacters(in: range.lowerBound...index, with: " ")
            }
        }
        index = code.index(after: index)
    }
    return nil
}

/// The extracted command when nothing else in `code` can spawn or write:
/// the first call is removed and the remainder runs the same checks, so a
/// second call (`os.system('ls'); os.execvp(...)`) limits instead of hiding.
private func extractedUnlessRemainder(
    _ command: String, code: String, pattern: String,
    remainderIsRisky: (String) -> Bool
) -> InterpreterExtract {
    guard let rest = removingFirstCall(code, pattern: pattern), remainderIsRisky(rest) == false else {
        return .limited
    }
    return .command(command)
}

func extractPython(_ code: String) -> InterpreterExtract {
    let folded = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if folded.isEmpty { return .limited }
    if let command = pythonShellCommand(folded) {
        // Only the first call is extracted; a second one is unknown.
        return extractedUnlessRemainder(
            command, code: folded,
            pattern: #"(?:(?:__import__\s*\(\s*['"]\w+['"]\s*\)|\b\w+)\s*\.\s*)?\b(?:system|popen|remove|unlink|rmtree|run|call|Popen|check_call|check_output)\s*\("#
        ) { pythonCodeCanSpawn($0) || pythonFileWrites($0).paths.isEmpty == false || pythonFileWrites($0).opaque }
    }
    if pythonCodeCanSpawn(folded) {
        return .limited
    }
    let paths = pythonFileWrites(folded).paths
    return paths.isEmpty ? .dataOnly : .command(writeProxyCommand(paths))
}

private func pythonShellCommand(_ code: String) -> String? {
    if let command = callStringArgument(code, names: ["os.system", "os.popen"]) {
        return command
    }
    if let command = importOsSystem(code) {
        return command
    }
    if let command = subprocessCommand(code) {
        return command
    }
    if let path = callStringArgument(code, names: ["os.remove", "os.unlink"]) {
        return reconstructedRm(path)
    }
    if let path = callStringArgument(code, names: ["shutil.rmtree"]) {
        return reconstructedRm(path, recursive: true)
    }
    return nil
}

private func importOsSystem(_ code: String) -> String? {
    let markers = [#"__import__('os').system"#, #"__import__("os").system"#]
    for marker in markers {
        if let command = callStringArgument(code, names: [marker]) {
            return command
        }
    }
    return nil
}

private func subprocessCommand(_ code: String) -> String? {
    let names = [
        "subprocess.run", "subprocess.call", "subprocess.Popen",
        "subprocess.check_call", "subprocess.check_output",
    ]
    if let command = callStringArgument(code, names: names) {
        return command
    }
    return callStringListArgument(code, names: names)
}

func extractNode(_ code: String) -> InterpreterExtract {
    let folded = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if folded.isEmpty { return .limited }
    if let command = nodeShellCommand(folded) {
        // Only the first call is extracted; a second one is unknown.
        return extractedUnlessRemainder(
            command, code: folded,
            pattern: #"(?:(?:require\s*\(\s*['"][\w:/]+['"]\s*\)|[\w$]+)\s*\.\s*)?\b(?:exec|execSync|unlinkSync|rmdirSync|rmSync|rm|unlink|rmdir)\s*\("#
        ) { nodeCodeCanSpawn($0) || nodeFileWrites($0).paths.isEmpty == false || nodeFileWrites($0).opaque }
    }
    if nodeCodeCanSpawn(folded) {
        return .limited
    }
    let paths = nodeFileWrites(folded).paths
    return paths.isEmpty ? .dataOnly : .command(writeProxyCommand(paths))
}

private func nodeShellCommand(_ code: String) -> String? {
    let execNames = [
        "require('child_process').execSync",
        "require(\"child_process\").execSync",
        "require('child_process').exec",
        "require(\"child_process\").exec",
        "require('node:child_process').execSync",
        "require(\"node:child_process\").execSync",
        "require('node:child_process').exec",
        "require(\"node:child_process\").exec",
        "child_process.execSync",
        "child_process.exec",
    ]
    if let command = callStringArgument(code, names: execNames) {
        return command
    }
    if let path = callStringArgument(code, names: ["fs.unlinkSync", "fs.rmdirSync"]) {
        return reconstructedRm(path)
    }
    if let path = callStringArgument(code, names: ["fs.rmSync", "fs.rm"]) {
        return reconstructedRm(path, recursive: code.contains("recursive"))
    }
    return nil
}

func extractRuby(_ code: String) -> InterpreterExtract {
    let folded = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if folded.isEmpty { return .limited }
    if let command = rubyShellCommand(folded) {
        // Only the first call is extracted; a second one is unknown.
        return extractedUnlessRemainder(
            command, code: folded,
            pattern: #"(?:(?:\b[A-Z]\w*\s*\.\s*)?\b(?:system|exec|delete|unlink|rm_rf|remove_entry_secure)\s*\(|`[^`]*`)"#
        ) { rubyCodeCanSpawn($0) || rubyFileWrites($0).paths.isEmpty == false || rubyFileWrites($0).opaque }
    }
    if rubyCodeCanSpawn(folded) {
        return .limited
    }
    let paths = rubyFileWrites(folded).paths
    return paths.isEmpty ? .dataOnly : .command(writeProxyCommand(paths))
}

private func rubyShellCommand(_ code: String) -> String? {
    if let command = callStringArgument(code, names: ["system", "exec"]) {
        return command
    }
    if let path = callStringArgument(code, names: ["File.delete", "File.unlink"]) {
        return reconstructedRm(path)
    }
    if let path = callStringArgument(code, names: ["FileUtils.rm_rf", "FileUtils.remove_entry_secure"]) {
        return reconstructedRm(path, recursive: true)
    }
    if let command = rubyBacktickCommand(code) {
        return command
    }
    return nil
}

private func rubyBacktickCommand(_ code: String) -> String? {
    guard let start = code.firstIndex(of: "`") else { return nil }
    let innerStart = code.index(after: start)
    guard let end = code[innerStart...].firstIndex(of: "`") else { return nil }
    let command = String(code[innerStart..<end])
    return command.isEmpty ? nil : command
}

private func callStringArgument(_ code: String, names: [String]) -> String? {
    for name in names {
        guard let range = code.range(of: name) else { continue }
        var index = range.upperBound
        while index < code.endIndex, code[index].isWhitespace {
            index = code.index(after: index)
        }
        guard index < code.endIndex, code[index] == "(" else { continue }
        index = code.index(after: index)
        while index < code.endIndex, code[index].isWhitespace {
            index = code.index(after: index)
        }
        if let quoted = readQuotedLiteral(in: code, startingAt: index) {
            return quoted.value.isEmpty ? nil : quoted.value
        }
    }
    return nil
}

private func callStringListArgument(_ code: String, names: [String]) -> String? {
    for name in names {
        guard let range = code.range(of: name) else { continue }
        var index = range.upperBound
        while index < code.endIndex, code[index].isWhitespace {
            index = code.index(after: index)
        }
        guard index < code.endIndex, code[index] == "(" else { continue }
        index = code.index(after: index)
        while index < code.endIndex, code[index].isWhitespace {
            index = code.index(after: index)
        }
        guard index < code.endIndex, code[index] == "[" else { continue }
        index = code.index(after: index)
        var parts: [String] = []
        while index < code.endIndex {
            while index < code.endIndex, code[index].isWhitespace || code[index] == "," {
                index = code.index(after: index)
            }
            if index < code.endIndex, code[index] == "]" {
                break
            }
            guard let quoted = readQuotedLiteral(in: code, startingAt: index) else {
                return nil
            }
            parts.append(quoted.value)
            index = quoted.end
        }
        if parts.isEmpty == false {
            return parts.joined(separator: " ")
        }
    }
    return nil
}

private func readQuotedLiteral(
    in text: String,
    startingAt start: String.Index
) -> (value: String, end: String.Index)? {
    guard start < text.endIndex else { return nil }
    let quote = text[start]
    guard quote == "'" || quote == "\"" else { return nil }
    var index = text.index(after: start)
    var value = ""
    while index < text.endIndex {
        let character = text[index]
        if character == "\\" {
            let next = text.index(after: index)
            guard next < text.endIndex else { return nil }
            value.append(text[next])
            index = text.index(after: next)
            continue
        }
        if character == quote {
            return (value, text.index(after: index))
        }
        value.append(character)
        index = text.index(after: index)
    }
    return nil
}

private func reconstructedRm(_ path: String, recursive: Bool = false) -> String {
    let flags = recursive ? "-rf " : ""
    return "rm \(flags)\(quoteIfNeeded(path))"
}

private func quoteIfNeeded(_ value: String) -> String {
    if value.isEmpty { return "''" }
    if value.contains(where: { $0.isWhitespace || $0 == "'" }) {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return value
}

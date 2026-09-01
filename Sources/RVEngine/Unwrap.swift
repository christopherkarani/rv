import Foundation
import RVDomain

/// Hard caps for recursive wrapper / interpreter extraction.
public enum UnwrapLimits: Sendable {
    public static let maxDepth = 8
    public static let maxBytes = 4_096
}

/// Inner command plus the wrappers peeled to reach it.
public struct UnwrappedCommand: Sendable, Equatable {
    public var command: ShellCommand
    public var layers: [WrapperKind]
    public var workingDirectory: WorkingDirectory?

    public init(
        command: ShellCommand,
        layers: [WrapperKind] = [],
        workingDirectory: WorkingDirectory? = nil
    ) {
        self.command = command
        self.layers = layers
        self.workingDirectory = workingDirectory
    }
}

/// Result of bounded unwrap. `.limited` is fail-closed, never an allow hint.
public enum UnwrapOutcome: Sendable, Equatable {
    case complete(UnwrappedCommand)
    case limited(layers: [WrapperKind])
}

/// Pure recursive extract. Does not evaluate policy.
public func unwrapCommand(
    _ command: ShellCommand,
    workingDirectory: WorkingDirectory? = nil,
    maxDepth: Int = UnwrapLimits.maxDepth,
    maxBytes: Int = UnwrapLimits.maxBytes
) -> UnwrapOutcome {
    unwrapText(
        command.rawValue,
        workingDirectory: workingDirectory,
        depth: 0,
        layers: [],
        maxDepth: maxDepth,
        maxBytes: maxBytes
    )
}

private func unwrapText(
    _ text: String,
    workingDirectory: WorkingDirectory?,
    depth: Int,
    layers: [WrapperKind],
    maxDepth: Int,
    maxBytes: Int
) -> UnwrapOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return .complete(
            UnwrappedCommand(
                command: ShellCommand(rawValue: trimmed),
                layers: layers,
                workingDirectory: workingDirectory
            )
        )
    }
    if trimmed.hasPrefix("\\") {
        if let stripped = stripLeadingBackslash(trimmed), stripped != trimmed {
            return unwrapText(
                stripped,
                workingDirectory: workingDirectory,
                depth: depth,
                layers: layers,
                maxDepth: maxDepth,
                maxBytes: maxBytes
            )
        }
    }

    switch peel(trimmed, workingDirectory: workingDirectory) {
    case .notWrapper:
        return .complete(
            UnwrappedCommand(
                command: ShellCommand(rawValue: trimmed),
                layers: layers,
                workingDirectory: workingDirectory
            )
        )
    case .limited(let kind):
        return .limited(layers: layers + [kind])
    case .next(let inner, let kind, let nextCwd):
        if inner.utf8.count > maxBytes {
            return .limited(layers: layers + [kind])
        }
        if depth + 1 > maxDepth {
            return .limited(layers: layers + [kind])
        }
        return unwrapText(
            inner,
            workingDirectory: nextCwd,
            depth: depth + 1,
            layers: layers + [kind],
            maxDepth: maxDepth,
            maxBytes: maxBytes
        )
    }
}

enum Peel: Equatable {
    case notWrapper
    case limited(WrapperKind)
    case next(String, WrapperKind, WorkingDirectory?)
}

private func peel(_ text: String, workingDirectory: WorkingDirectory?) -> Peel {
    if let sink = peelExecutingSink(text, workingDirectory: workingDirectory) {
        return sink
    }
    let tokens = tokenizeCommand(text)
    guard let first = tokens.first else { return .notWrapper }
    let head = basename(first.decoded).lowercased()
    if head == "timeout" {
        return peelTimeout(tokens, workingDirectory: workingDirectory)
    }
    if head == "nice" {
        return peelNice(tokens, workingDirectory: workingDirectory)
    }
    if head == "mise" {
        return peelMise(tokens, workingDirectory: workingDirectory)
    }
    if head == "ssh" {
        return peelSSH(tokens, workingDirectory: workingDirectory)
    }
    if head == "sudo" {
        return peelSudo(tokens, workingDirectory: workingDirectory)
    }
    if head == "env" {
        return peelEnv(tokens, workingDirectory: workingDirectory)
    }
    if head == "command" {
        return peelCommandWrapper(tokens, workingDirectory: workingDirectory)
    }
    if let kind = shellKind(head) {
        return peelShell(tokens, kind: kind, workingDirectory: workingDirectory)
    }
    if isPythonExecutable(head) {
        return peelInterpreter(
            tokens,
            kind: .python,
            flags: ["-c"],
            extract: extractPython,
            workingDirectory: workingDirectory
        )
    }
    if isNodeExecutable(head) {
        return peelInterpreter(
            tokens,
            kind: .node,
            flags: ["-e", "--eval", "-p", "--print"],
            extract: extractNode,
            workingDirectory: workingDirectory
        )
    }
    if isRubyExecutable(head) {
        return peelInterpreter(
            tokens,
            kind: .ruby,
            flags: ["-e"],
            extract: extractRuby,
            workingDirectory: workingDirectory
        )
    }
    return .notWrapper
}

private func shellKind(_ head: String) -> WrapperKind? {
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

private func peelSudo(_ tokens: [CommandToken], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    var cwd = workingDirectory
    while index < tokens.count {
        let token = tokens[index].decoded
        if token == "--" {
            index += 1
            break
        }
        if token.hasPrefix("--") {
            if let value = attachedValue(token, long: "--chdir") {
                cwd = resolveWorkingDirectory(value, current: cwd)
                index += 1
                continue
            }
            if sudoLongArgFlags.contains(token) {
                guard index + 1 < tokens.count else { return .limited(.sudo) }
                if token == "--chdir" {
                    cwd = resolveWorkingDirectory(tokens[index + 1].decoded, current: cwd)
                }
                index += 2
                continue
            }
            if sudoLongFlags.contains(token) {
                index += 1
                continue
            }
            return .limited(.sudo)
        }
        if token.hasPrefix("-") {
            if token == "-D" {
                guard index + 1 < tokens.count else { return .limited(.sudo) }
                cwd = resolveWorkingDirectory(tokens[index + 1].decoded, current: cwd)
                index += 2
                continue
            }
            if sudoShortArgFlags.contains(token) {
                guard index + 1 < tokens.count else { return .limited(.sudo) }
                index += 2
                continue
            }
            index += 1
            continue
        }
        break
    }
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty { return .notWrapper }
    return .next(renderCommand(rest), .sudo, cwd)
}

private let sudoShortArgFlags: Set<String> = ["-u", "-g", "-h", "-p", "-C", "-U", "-T"]
private let sudoLongArgFlags: Set<String> = [
    "--user", "--group", "--host", "--prompt", "--close-from", "--chdir",
    "--other-user", "--command-timeout",
]
private let sudoLongFlags: Set<String> = [
    "--preserve-env", "--login", "--shell", "--non-interactive", "--set-home",
    "--reset-timestamp", "--askpass", "--background", "--preserve-groups",
    "--stdin", "--help", "--version",
]

private func peelEnv(_ tokens: [CommandToken], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    var cwd = workingDirectory
    while index < tokens.count {
        let token = tokens[index].decoded
        if token == "-" {
            index += 1
            continue
        }
        if token == "-S" || token == "--split-string" {
            return .limited(.env)
        }
        if token == "-C" || token == "--chdir" {
            guard index + 1 < tokens.count else { return .limited(.env) }
            cwd = resolveWorkingDirectory(tokens[index + 1].decoded, current: cwd)
            index += 2
            continue
        }
        if let value = attachedValue(token, long: "--chdir") {
            cwd = resolveWorkingDirectory(value, current: cwd)
            index += 1
            continue
        }
        if token == "-u" || token == "--unset" {
            guard index + 1 < tokens.count else { return .limited(.env) }
            index += 2
            continue
        }
        if token.hasPrefix("--unset=") {
            index += 1
            continue
        }
        if token.hasPrefix("-") {
            index += 1
            continue
        }
        if token.contains("=") {
            index += 1
            continue
        }
        break
    }
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty { return .notWrapper }
    return .next(renderCommand(rest), .env, cwd)
}

private func peelCommandWrapper(
    _ tokens: [CommandToken],
    workingDirectory: WorkingDirectory?
) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].decoded
        if token == "-v" || token == "-V" {
            return .notWrapper
        }
        if token == "-p" || token.hasPrefix("-") {
            index += 1
            continue
        }
        break
    }
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty { return .notWrapper }
    return .next(renderCommand(rest), .command, workingDirectory)
}

private func peelShell(
    _ tokens: [CommandToken],
    kind: WrapperKind,
    workingDirectory: WorkingDirectory?
) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].decoded
        if token == "--" {
            return .notWrapper
        }
        if token == "-c" || token == "--command" {
            guard index + 1 < tokens.count else { return .limited(kind) }
            return peelShellPayload(tokens[index + 1], kind: kind, cwd: workingDirectory)
        }
        if let value = attachedValue(token, long: "--command") {
            return peelShellPayload(
                CommandToken(decoded: value, wasQuoted: tokens[index].wasQuoted),
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
    _ token: CommandToken,
    kind: WrapperKind,
    cwd: WorkingDirectory?
) -> Peel {
    if token.wasQuoted == false {
        return .limited(kind)
    }
    if token.decoded.contains("$") || token.decoded.contains("`") {
        return .limited(kind)
    }
    return .next(token.decoded, kind, cwd)
}

private func peelInterpreter(
    _ tokens: [CommandToken],
    kind: WrapperKind,
    flags: Set<String>,
    extract: (String) -> InterpreterExtract,
    workingDirectory: WorkingDirectory?
) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].decoded
        if flags.contains(token) {
            guard index + 1 < tokens.count else { return .limited(kind) }
            return interpreterPeel(extract(tokens[index + 1].decoded), kind: kind, cwd: workingDirectory)
        }
        if kind == .ruby, token.hasPrefix("-e"), token.count > 2 {
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

private enum InterpreterExtract: Equatable {
    case command(String)
    case dataOnly
    case limited
}

private func extractPython(_ code: String) -> InterpreterExtract {
    let folded = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if let command = pythonShellCommand(folded) {
        return .command(command)
    }
    if looksLikePythonDataOnly(folded) {
        return .dataOnly
    }
    return .limited
}

private func looksLikePythonDataOnly(_ code: String) -> Bool {
    splitTopLevel(code, separator: ";").allSatisfy { part in
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("import ") || trimmed.hasPrefix("from ") { return true }
        return trimmed.hasPrefix("print(") || trimmed.hasPrefix("print (")
            || trimmed.hasPrefix("pprint(") || trimmed.hasPrefix("pprint (")
    }
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

private func extractNode(_ code: String) -> InterpreterExtract {
    let folded = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if let command = nodeShellCommand(folded) {
        return .command(command)
    }
    if looksLikeNodeDataOnly(folded) {
        return .dataOnly
    }
    return .limited
}

private func looksLikeNodeDataOnly(_ code: String) -> Bool {
    splitTopLevel(code, separator: ";").allSatisfy { part in
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.hasPrefix("console.log(") || trimmed.hasPrefix("console.info(")
            || trimmed.hasPrefix("console.debug(") || trimmed.hasPrefix("console.warn(")
            || trimmed.hasPrefix("console.error(")
    }
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

private func extractRuby(_ code: String) -> InterpreterExtract {
    let folded = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if let command = rubyShellCommand(folded) {
        return .command(command)
    }
    if looksLikeRubyDataOnly(folded) {
        return .dataOnly
    }
    return .limited
}

private func looksLikeRubyDataOnly(_ code: String) -> Bool {
    if code.contains("`") || code.contains("%x") {
        return false
    }
    return splitTopLevel(code, separator: ";").allSatisfy { part in
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.hasPrefix("puts ") || trimmed.hasPrefix("puts(")
            || trimmed.hasPrefix("print ") || trimmed.hasPrefix("print(")
            || trimmed.hasPrefix("p ") || trimmed.hasPrefix("p(")
            || trimmed.hasPrefix("pp ") || trimmed.hasPrefix("pp(")
    }
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

private func splitTopLevel(_ text: String, separator: Character) -> [String] {
    var parts: [String] = []
    var current = ""
    var quote: Character?
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        if let currentQuote = quote {
            current.append(character)
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    current.append(text[next])
                    index = next
                }
            } else if character == currentQuote {
                quote = nil
            }
            index = text.index(after: index)
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            current.append(character)
            index = text.index(after: index)
            continue
        }
        if character == separator {
            parts.append(current)
            current = ""
            index = text.index(after: index)
            continue
        }
        current.append(character)
        index = text.index(after: index)
    }
    parts.append(current)
    return parts
}

private func attachedValue(_ token: String, long: String) -> String? {
    let prefix = long + "="
    guard token.hasPrefix(prefix) else { return nil }
    let value = String(token.dropFirst(prefix.count))
    return value.isEmpty ? nil : value
}

private func resolveWorkingDirectory(
    _ apparent: String,
    current: WorkingDirectory?
) -> WorkingDirectory? {
    let path = lexicalFilesystemPath(
        apparent,
        workingDirectory: current?.rawValue,
        homeDirectory: nil
    )
    return WorkingDirectory(validating: path)
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

func renderCommand(_ tokens: [CommandToken]) -> String {
    tokens.map(renderToken).joined(separator: " ")
}

func renderToken(_ token: CommandToken) -> String {
    if token.wasQuoted || token.decoded.contains(where: { $0.isWhitespace }) {
        return "'" + token.decoded.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return token.decoded
}

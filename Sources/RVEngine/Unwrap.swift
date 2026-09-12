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
    if pythonDangerMarkerPresent(folded) {
        return .limited
    }
    if let command = pythonOpenWriteCommand(folded) {
        return .command(command)
    }
    if pythonOpenHasWriteMode(folded) {
        return .limited
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
        if pythonDangerMarkerPresent(trimmed) { return false }
        if trimmed.hasPrefix("import ") || trimmed.hasPrefix("from ") { return true }
        if trimmed.hasPrefix("print(") || trimmed.hasPrefix("print (")
            || trimmed.hasPrefix("pprint(") || trimmed.hasPrefix("pprint (")
        {
            return true
        }
        if trimmed.hasPrefix("json.dump") { return true }
        if looksLikePythonAssignment(trimmed) { return true }
        return true
    }
}

private func looksLikePythonAssignment(_ code: String) -> Bool {
    guard let equal = code.firstIndex(of: "=") else { return false }
    let next = code.index(after: equal)
    if next < code.endIndex, code[next] == "=" { return false }
    if equal > code.startIndex {
        let previous = code[code.index(before: equal)]
        if previous == "!" || previous == "<" || previous == ">" { return false }
    }
    return code[..<equal].trimmingCharacters(in: .whitespaces).isEmpty == false
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
    if nodeDangerMarkerPresent(folded) {
        return .limited
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
        if nodeDangerMarkerPresent(trimmed) { return false }
        if trimmed.hasPrefix("console.log(") || trimmed.hasPrefix("console.info(")
            || trimmed.hasPrefix("console.debug(") || trimmed.hasPrefix("console.warn(")
            || trimmed.hasPrefix("console.error(")
        {
            return true
        }
        if trimmed.hasPrefix("JSON.parse(") || trimmed.hasPrefix("JSON.stringify(") {
            return true
        }
        return true
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

private func reconstructedOverwrite(path: String, content: String?) -> String {
    let destination = quoteIfNeeded(path)
    if let content, content.isEmpty == false,
        content.contains(where: { $0.isNewline }) == false
    {
        return "echo \(quoteIfNeeded(content)) > \(destination)"
    }
    return "true > \(destination)"
}

private func pythonDangerMarkerPresent(_ code: String) -> Bool {
    if containsCall(named: "os.system", in: code) { return true }
    if containsCall(named: "os.popen", in: code) { return true }
    if containsCall(named: "shutil.rmtree", in: code) { return true }
    if containsCall(named: "os.remove", in: code) { return true }
    if containsCall(named: "os.unlink", in: code) { return true }
    if code.contains("subprocess.") { return true }
    if containsCall(named: #"__import__('os').system"#, in: code) { return true }
    if containsCall(named: #"__import__("os").system"#, in: code) { return true }
    return false
}

private func nodeDangerMarkerPresent(_ code: String) -> Bool {
    if code.contains("child_process") {
        if containsCall(named: "execSync", in: code) { return true }
        if containsCall(named: "exec", in: code) { return true }
    }
    if containsCall(named: "fs.unlinkSync", in: code) { return true }
    if containsCall(named: "fs.rmdirSync", in: code) { return true }
    if containsCall(named: "fs.rmSync", in: code) { return true }
    if containsCall(named: "fs.rm", in: code) { return true }
    return false
}

private func containsCall(named name: String, in code: String) -> Bool {
    var search = code.startIndex
    while let found = code.range(of: name, range: search..<code.endIndex) {
        var index = found.upperBound
        skipWhitespace(&index, in: code)
        if index < code.endIndex, code[index] == "(" {
            return true
        }
        search = found.upperBound
    }
    return false
}

private struct PythonOpenCall: Equatable {
    var path: String?
    var isWrite: Bool
    var writeContent: String?
}

private func pythonOpenWriteCommand(_ code: String) -> String? {
    guard let call = parsePythonOpenCall(code), call.isWrite, let path = call.path else {
        return nil
    }
    return reconstructedOverwrite(path: path, content: call.writeContent)
}

private func pythonOpenHasWriteMode(_ code: String) -> Bool {
    parsePythonOpenCall(code)?.isWrite == true
}

private func parsePythonOpenCall(_ code: String) -> PythonOpenCall? {
    guard let openIndex = findPythonOpenParen(in: code) else { return nil }
    var index = openIndex
    skipWhitespace(&index, in: code)
    var path: String?
    if let quoted = readQuotedLiteral(in: code, startingAt: index) {
        path = quoted.value
        index = quoted.end
    } else {
        while index < code.endIndex {
            let character = code[index]
            if character == "," || character == ")" { break }
            if character == "'" || character == "\"" { break }
            index = code.index(after: index)
        }
    }
    skipWhitespace(&index, in: code)
    var mode = "r"
    if index < code.endIndex, code[index] == "," {
        index = code.index(after: index)
        skipWhitespace(&index, in: code)
        if let keyword = readPythonModeKeyword(in: code, startingAt: &index) {
            mode = keyword
        } else if let quoted = readQuotedLiteral(in: code, startingAt: index) {
            mode = quoted.value
            index = quoted.end
        }
    }
    var writeContent: String?
    if let close = matchingCloseParen(in: code, afterOpen: openIndex) {
        var after = code.index(after: close)
        skipWhitespace(&after, in: code)
        if code[after...].hasPrefix(".write") {
            guard let writeNameEnd = code.index(after, offsetBy: 6, limitedBy: code.endIndex) else {
                return PythonOpenCall(path: path, isWrite: isPythonWriteMode(mode), writeContent: nil)
            }
            var writeIndex = writeNameEnd
            skipWhitespace(&writeIndex, in: code)
            if writeIndex < code.endIndex, code[writeIndex] == "(" {
                writeIndex = code.index(after: writeIndex)
                skipWhitespace(&writeIndex, in: code)
                if let quoted = readQuotedLiteral(in: code, startingAt: writeIndex) {
                    writeContent = quoted.value
                }
            }
        }
    }
    return PythonOpenCall(path: path, isWrite: isPythonWriteMode(mode), writeContent: writeContent)
}

private func findPythonOpenParen(in code: String) -> String.Index? {
    var search = code.startIndex
    while let found = code.range(of: "open", range: search..<code.endIndex) {
        if found.lowerBound > code.startIndex {
            let previous = code[code.index(before: found.lowerBound)]
            if previous.isLetter || previous.isNumber || previous == "_" {
                search = found.upperBound
                continue
            }
        }
        var index = found.upperBound
        skipWhitespace(&index, in: code)
        if index < code.endIndex, code[index] == "(" {
            return code.index(after: index)
        }
        search = found.upperBound
    }
    return nil
}

private func readPythonModeKeyword(in code: String, startingAt index: inout String.Index) -> String? {
    guard code[index...].hasPrefix("mode") else { return nil }
    guard let afterName = code.index(index, offsetBy: 4, limitedBy: code.endIndex) else {
        return nil
    }
    var cursor = afterName
    skipWhitespace(&cursor, in: code)
    guard cursor < code.endIndex, code[cursor] == "=" else { return nil }
    cursor = code.index(after: cursor)
    skipWhitespace(&cursor, in: code)
    guard let quoted = readQuotedLiteral(in: code, startingAt: cursor) else { return nil }
    index = quoted.end
    return quoted.value
}

private func isPythonWriteMode(_ mode: String) -> Bool {
    mode.contains { character in
        character == "w" || character == "a" || character == "x" || character == "+"
    }
}

private func matchingCloseParen(in text: String, afterOpen open: String.Index) -> String.Index? {
    var depth = 1
    var index = open
    var quote: Character?
    while index < text.endIndex {
        let character = text[index]
        if let currentQuote = quote {
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                index = text.index(after: next)
                continue
            }
            if character == currentQuote {
                quote = nil
            }
            index = text.index(after: index)
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            index = text.index(after: index)
            continue
        }
        if character == "(" {
            depth += 1
        } else if character == ")" {
            depth -= 1
            if depth == 0 {
                return index
            }
        }
        index = text.index(after: index)
    }
    return nil
}

private func skipWhitespace(_ index: inout String.Index, in text: String) {
    while index < text.endIndex, text[index].isWhitespace {
        index = text.index(after: index)
    }
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

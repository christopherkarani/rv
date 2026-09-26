/// C1 single recursive unwrap (T2 seam).
///
/// One recursive unwrap over `Argv` with one `UnwrapBudget` value type. This
/// file consolidates the former `Unwrap*.swift` implementations (prefix
/// wrappers, SSH, executing sinks, shells, interpreters) behind a single
/// `ShellPipeline.unwrap` recursion and a single `peel` dispatch keyed on
/// `argv.program`. Tokens carry quoting/ANSI-C provenance parallel to the argv
/// words; handlers consume tokens while dispatch keys on Argv.
///
/// Behavior is identical to the pre-T2 pipeline: same peel outcomes, same
/// budget cutoffs, same fail-closed `.limited` cases. `Normalize`,
/// `unwrapCommand`, and `CommandPeel` keep their signatures and delegate here.
import Foundation
import RVDomain

// MARK: - Budget

/// Single depth/bytes policy for recursive unwrap.
///
/// One value type replaces the scattered depth/bytes pairs. Defaults match
/// the pre-T2 `UnwrapLimits` caps.
public struct UnwrapBudget: Sendable, Equatable, Hashable {
    public var maxDepth: Int
    public var maxBytes: Int

    public init(maxDepth: Int = 8, maxBytes: Int = 4_096) {
        self.maxDepth = maxDepth
        self.maxBytes = maxBytes
    }

    public static let `default` = UnwrapBudget()
}

// MARK: - Public unwrap vocabulary (pre-T2 API, unchanged signatures)

/// Hard caps for recursive wrapper / interpreter extraction.
///
/// Single source of truth is `UnwrapBudget`; this enum preserves the pre-T2
/// public spelling used by analyzer defaults and the corpus gate.
public enum UnwrapLimits: Sendable {
    public static let maxDepth = UnwrapBudget.default.maxDepth
    public static let maxBytes = UnwrapBudget.default.maxBytes
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

    public var executing: ExecutingCommand {
        ExecutingCommand(rawValue: command.rawValue)
    }
}

/// Result of bounded unwrap. `.limited` is fail-closed, never an allow hint.
public enum UnwrapOutcome: Sendable, Equatable {
    case complete(UnwrappedCommand)
    case limited(layers: [WrapperKind])
}

/// Pure recursive extract. Does not evaluate policy.
///
/// Thin adapter over the single `ShellPipeline.unwrap` recursion; the
/// signature is unchanged from pre-T2.
public func unwrapCommand(
    _ command: ShellCommand,
    workingDirectory: WorkingDirectory? = nil,
    maxDepth: Int = UnwrapLimits.maxDepth,
    maxBytes: Int = UnwrapLimits.maxBytes
) -> UnwrapOutcome {
    ShellPipeline.unwrap(
        command.rawValue,
        workingDirectory: workingDirectory,
        budget: UnwrapBudget(maxDepth: maxDepth, maxBytes: maxBytes),
        depth: 0,
        layers: []
    )
}

// MARK: - Single recursive unwrap

extension ShellPipeline {
    /// Pure recursive extract over `Argv`. Does not evaluate policy.
    static func unwrap(
        _ text: String,
        workingDirectory: WorkingDirectory?,
        budget: UnwrapBudget,
        depth: Int,
        layers: [WrapperKind]
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
                return unwrap(
                    stripped,
                    workingDirectory: workingDirectory,
                    budget: budget,
                    depth: depth,
                    layers: layers
                )
            }
        }

        let tokens = ShellPipeline.tokenize(trimmed)
        let argv = Argv(tokens: tokens)
        switch peel(text: trimmed, tokens: tokens, argv: argv, workingDirectory: workingDirectory) {
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
            if inner.utf8.count > budget.maxBytes {
                return .limited(layers: layers + [kind])
            }
            if depth + 1 > budget.maxDepth {
                return .limited(layers: layers + [kind])
            }
            return unwrap(
                inner,
                workingDirectory: nextCwd,
                budget: budget,
                depth: depth + 1,
                layers: layers + [kind]
            )
        }
    }

    /// Single wrapper dispatch keyed on `argv.program`.
    ///
    /// The executing-sink check runs first on raw text (pipes/heredocs are
    /// text-level structure); every other wrapper dispatches on the argv head
    /// with per-token quoting provenance from `tokens`.
    static func peel(
        text: String,
        tokens: [Token],
        argv: Argv?,
        workingDirectory: WorkingDirectory?
    ) -> Peel {
        if let sink = peelExecutingSink(text, workingDirectory: workingDirectory) {
            return sink
        }
        guard let first = tokens.first, first.isNewline == false, let argv else {
            return .notWrapper
        }
        let head = basename(argv.program).lowercased()
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
}

/// Compatibility overload preserving the pre-T2 `[CommandToken]` call shape
/// (used by `Tests/RVEngineTests/UnwrapAdversarialTests.swift`). Converts and
/// delegates to the single `Token`-based implementation below.
func peelTimeout(_ tokens: [CommandToken], workingDirectory: WorkingDirectory?) -> Peel {
    peelTimeout(
        tokens.map { Token(lexeme: $0.decoded, wasQuoted: $0.wasQuoted, wasAnsiC: $0.wasAnsiC) },
        workingDirectory: workingDirectory
    )
}
// MARK: - Peel result

enum Peel: Equatable {
    case notWrapper
    case limited(WrapperKind)
    case next(String, WrapperKind, WorkingDirectory?)
}

// MARK: - Wrapper handlers (single Token-based implementations)

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

private func peelSudo(_ tokens: [Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    var cwd = workingDirectory
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            index += 1
            break
        }
        if token.hasPrefix("--") {
            if let value = attachedOptionValue(token, long: "--chdir") {
                cwd = resolveWorkingDirectory(value, current: cwd)
                index += 1
                continue
            }
            if sudoLongArgFlags.contains(token) {
                guard index + 1 < tokens.count else { return .limited(.sudo) }
                if token == "--chdir" {
                    cwd = resolveWorkingDirectory(tokens[index + 1].lexeme, current: cwd)
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
                cwd = resolveWorkingDirectory(tokens[index + 1].lexeme, current: cwd)
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

private func peelEnv(_ tokens: [Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    var cwd = workingDirectory
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "-" {
            index += 1
            continue
        }
        if token == "-S" || token == "--split-string" {
            return .limited(.env)
        }
        if token == "-C" || token == "--chdir" {
            guard index + 1 < tokens.count else { return .limited(.env) }
            cwd = resolveWorkingDirectory(tokens[index + 1].lexeme, current: cwd)
            index += 2
            continue
        }
        if let value = attachedOptionValue(token, long: "--chdir") {
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
    _ tokens: [Token],
    workingDirectory: WorkingDirectory?
) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].lexeme
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
    _ tokens: [Token],
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
                Token(lexeme: value, wasQuoted: tokens[index].wasQuoted),
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
private func peelShellPayload(
    _ token: Token,
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

private func peelInterpreter(
    _ tokens: [Token],
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
    _ payload: Token,
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

private enum InterpreterExtract: Equatable {
    case command(String)
    case dataOnly
    case limited
}

private func extractPython(_ code: String) -> InterpreterExtract {
    let folded = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if folded.isEmpty { return .limited }
    if let command = pythonShellCommand(folded) {
        return .command(command)
    }
    if looksLikePythonSpawn(folded) {
        return .limited
    }
    return .dataOnly
}

private func looksLikePythonSpawn(_ code: String) -> Bool {
    pythonSpawnMarkers.contains { code.contains($0) }
}

private let pythonSpawnMarkers: [String] = [
    "os.system(", "os.system (",
    "os.popen(", "os.popen (",
    "subprocess.run(", "subprocess.run (",
    "subprocess.call(", "subprocess.call (",
    "subprocess.Popen(", "subprocess.Popen (",
    "subprocess.check_call(", "subprocess.check_call (",
    "subprocess.check_output(", "subprocess.check_output (",
    "shutil.rmtree(", "shutil.rmtree (",
    "os.remove(", "os.remove (",
    "os.unlink(", "os.unlink (",
    "__import__('os').system(", #"__import__("os").system("#,
]

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
    if folded.isEmpty { return .limited }
    if let command = nodeShellCommand(folded) {
        return .command(command)
    }
    if looksLikeNodeSpawn(folded) {
        return .limited
    }
    return .dataOnly
}

private func looksLikeNodeSpawn(_ code: String) -> Bool {
    nodeSpawnMarkers.contains { code.contains($0) }
}

private let nodeSpawnMarkers: [String] = [
    "child_process.exec",
    "child_process.execSync",
    "fs.unlinkSync(", "fs.unlinkSync (",
    "fs.rmdirSync(", "fs.rmdirSync (",
    "fs.rmSync(", "fs.rmSync (",
    "fs.rm(", "fs.rm (",
]

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
    if folded.isEmpty { return .limited }
    if let command = rubyShellCommand(folded) {
        return .command(command)
    }
    if looksLikeRubySpawn(folded) {
        return .limited
    }
    return .dataOnly
}

private func looksLikeRubySpawn(_ code: String) -> Bool {
    if code.contains("`") || code.contains("%x") {
        return true
    }
    return rubySpawnMarkers.contains { code.contains($0) }
}

private let rubySpawnMarkers: [String] = [
    "system(", "system (",
    "exec(", "exec (",
    "File.delete(", "File.delete (",
    "File.unlink(", "File.unlink (",
    "FileUtils.rm_rf(", "FileUtils.rm_rf (",
    "FileUtils.remove_entry_secure(", "FileUtils.remove_entry_secure (",
]

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

private func attachedOptionValue(_ token: String, long: String) -> String? {
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
        workingDirectory: current,
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

private func renderCommand(_ tokens: [Token]) -> String {
    tokens.map(renderToken).joined(separator: " ")
}

private func renderToken(_ token: Token) -> String {
    if token.wasQuoted || token.lexeme.contains(where: { $0.isWhitespace }) {
        return "'" + token.lexeme.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return token.lexeme
}

private func peelTimeout(_ tokens: [Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            index += 1
            break
        }
        if timeoutFlags.contains(token) {
            index += 1
            continue
        }
        if timeoutArgFlags.contains(token) {
            guard index + 1 < tokens.count else { return .limited(.timeout) }
            index += 2
            continue
        }
        if attachedOptionValue(token, long: "--kill-after") != nil
            || attachedOptionValue(token, long: "--signal") != nil
        {
            index += 1
            continue
        }
        if token.hasPrefix("-") {
            return .limited(.timeout)
        }
        break
    }
    guard index < tokens.count else { return .limited(.timeout) }
    guard looksLikeTimeoutDuration(tokens[index].lexeme) else {
        return .limited(.timeout)
    }
    index += 1
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty { return .limited(.timeout) }
    return .next(renderCommand(rest), .timeout, workingDirectory)
}

private func peelNice(_ tokens: [Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    var sawOption = false
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            index += 1
            break
        }
        if token == "-n" || token == "--adjustment" {
            guard index + 1 < tokens.count else { return .limited(.nice) }
            index += 2
            sawOption = true
            continue
        }
        if attachedOptionValue(token, long: "--adjustment") != nil {
            index += 1
            sawOption = true
            continue
        }
        if token.hasPrefix("-n"), token.hasPrefix("--") == false, token != "-n" {
            index += 1
            sawOption = true
            continue
        }
        if looksLikeNiceAdjustment(token) {
            index += 1
            sawOption = true
            continue
        }
        if token.hasPrefix("-") {
            return .limited(.nice)
        }
        break
    }
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty {
        return sawOption ? .limited(.nice) : .notWrapper
    }
    return .next(renderCommand(rest), .nice, workingDirectory)
}

private func peelMise(_ tokens: [Token], workingDirectory: WorkingDirectory?) -> Peel {
    guard tokens.count >= 2 else { return .notWrapper }
    let subcommand = tokens[1].lexeme.lowercased()
    guard subcommand == "exec" || subcommand == "x" else { return .notWrapper }
    let index = 2
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            let rest = Array(tokens.dropFirst(index + 1))
            if rest.isEmpty { return .limited(.mise) }
            return .next(renderCommand(rest), .mise, workingDirectory)
        }
        if token == "-c" || token == "--command" {
            guard index + 1 < tokens.count else { return .limited(.mise) }
            return peelShellPayload(tokens[index + 1], kind: .mise, cwd: workingDirectory)
        }
        if let value = attachedOptionValue(token, long: "--command") {
            return peelShellPayload(
                Token(lexeme: value, wasQuoted: tokens[index].wasQuoted),
                kind: .mise,
                cwd: workingDirectory
            )
        }
        return .limited(.mise)
    }
    return .limited(.mise)
}

private let timeoutFlags: Set<String> = [
    "--foreground", "--preserve-status", "--verbose", "-v",
]
private let timeoutArgFlags: Set<String> = [
    "--kill-after", "-k", "--signal", "-s",
]

private func looksLikeTimeoutDuration(_ token: String) -> Bool {
    guard token.isEmpty == false else { return false }
    var sawDigit = false
    var sawDot = false
    var index = token.startIndex
    while index < token.endIndex {
        let character = token[index]
        let next = token.index(after: index)
        if character.isASCII, character.isNumber {
            sawDigit = true
            index = next
            continue
        }
        if character == ".", sawDot == false, sawDigit {
            sawDot = true
            index = next
            continue
        }
        if next == token.endIndex, sawDigit, "smhd".contains(character) {
            return true
        }
        return false
    }
    return sawDigit
}

private func looksLikeNiceAdjustment(_ token: String) -> Bool {
    guard token.hasPrefix("-") || token.hasPrefix("+") else { return false }
    if token.hasPrefix("--") { return false }
    let body = token.dropFirst()
    return body.isEmpty == false && body.allSatisfy(\.isNumber)
}

private func peelSSH(_ tokens: [Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            index += 1
            break
        }
        if token.hasPrefix("-") == false || token == "-" {
            break
        }
        switch consumeSSHOption(tokens, at: index) {
        case .unknown, .missingArgument:
            return .notWrapper
        case .consumed(let next):
            index = next
        }
    }
    guard index < tokens.count else { return .notWrapper }
    index += 1
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty { return .notWrapper }
    for token in rest {
        if token.wasQuoted, token.lexeme.contains("$") || token.lexeme.contains("`") {
            return .limited(.ssh)
        }
    }
    if rest.count == 1 {
        return .next(rest[0].lexeme, .ssh, workingDirectory)
    }
    return .next(renderCommand(rest), .ssh, workingDirectory)
}

private enum SSHOptionParse {
    case consumed(Int)
    case unknown
    case missingArgument
}

private func consumeSSHOption(_ tokens: [Token], at index: Int) -> SSHOptionParse {
    let token = tokens[index].lexeme
    if token.hasPrefix("--") {
        if let equals = token.firstIndex(of: "=") {
            let name = String(token[token.index(token.startIndex, offsetBy: 2)..<equals])
            return sshLongArgNames.contains(name) ? .consumed(index + 1) : .unknown
        }
        let name = String(token.dropFirst(2))
        guard sshLongArgNames.contains(name) else { return .unknown }
        guard index + 1 < tokens.count else { return .missingArgument }
        return .consumed(index + 2)
    }
    let body = token.dropFirst()
    guard body.isEmpty == false else { return .unknown }
    let characters = Array(body)
    var offset = 0
    while offset < characters.count {
        let flag = characters[offset]
        if sshArgShort.contains(flag) {
            if offset + 1 < characters.count {
                return .consumed(index + 1)
            }
            guard index + 1 < tokens.count else { return .missingArgument }
            return .consumed(index + 2)
        }
        if sshFlagShort.contains(flag) {
            offset += 1
            continue
        }
        return .unknown
    }
    return .consumed(index + 1)
}

private let sshFlagShort: Set<Character> = [
    "4", "6", "A", "a", "C", "f", "G", "g", "K", "k", "M", "N", "n",
    "q", "s", "T", "t", "V", "v", "X", "x", "Y", "y",
]
private let sshArgShort: Set<Character> = [
    "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m",
    "O", "o", "p", "Q", "R", "S", "W", "w",
]
private let sshLongArgNames: Set<String> = [
    "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m",
    "O", "o", "p", "Q", "R", "S", "W", "w",
    "bind-address", "cipher", "dynamic", "log-file", "escape", "config",
    "pkcs11", "identity", "identity-file", "jump", "jump-host", "local",
    "local-forward", "login", "login-name", "mac", "option", "port", "query",
    "remote", "remote-forward", "ctl-cmd", "ctl-path", "stdio-forward", "tun",
]

func peelExecutingSink(_ text: String, workingDirectory: WorkingDirectory?) -> Peel? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    let heredoc = extractHeredoc(trimmed)
    let header = heredoc?.header ?? trimmed
    let heredocBody = heredoc?.body

    let pipes = splitTopLevelPipes(header)
    guard let sinkIndex = lastExecutingSinkIndex(pipes) else {
        return nil
    }
    let consumer = pipes[sinkIndex]
    let hasPipe = sinkIndex >= 1
    let producer: String? = hasPipe ? pipes[..<sinkIndex].joined(separator: " | ") : nil

    if hasPipe, let payload = peelPayloadWrapper(consumer, cwd: workingDirectory) {
        return payload
    }

    return peelStdinExecuting(
        consumer: consumer,
        producer: producer,
        heredocBody: heredocBody,
        cwd: workingDirectory
    )
}

private func peelPayloadWrapper(_ consumer: String, cwd: WorkingDirectory?) -> Peel? {
    let tokens = ShellPipeline.tokenize(consumer)
    guard let first = tokens.first else { return nil }
    let head = basename(first.lexeme).lowercased()
    guard let kind = sinkKind(head) else { return nil }

    switch kind {
    case .bash, .sh, .zsh:
        return peelShellDashC(tokens, kind: kind, cwd: cwd)
    case .python, .node, .ruby:
        return peelInterpreterProgramFlag(tokens, kind: kind)
    default:
        return nil
    }
}

private func peelShellDashC(
    _ tokens: [Token],
    kind: WrapperKind,
    cwd: WorkingDirectory?
) -> Peel? {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token == "--" {
            return nil
        }
        if token == "-c" || token == "--command" {
            guard index + 1 < tokens.count else { return .limited(kind) }
            return peelShellPayload(tokens[index + 1], kind: kind, cwd: cwd)
        }
        if let value = attachedOptionValue(token, long: "--command") {
            return peelShellPayload(
                Token(lexeme: value, wasQuoted: tokens[index].wasQuoted),
                kind: kind,
                cwd: cwd
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
            return peelShellPayload(tokens[index + 1], kind: kind, cwd: cwd)
        }
        if token.hasPrefix("-") {
            index += 1
            continue
        }
        return nil
    }
    return nil
}

private func peelInterpreterProgramFlag(_ tokens: [Token], kind: WrapperKind) -> Peel? {
    let flags: Set<String>
    switch kind {
    case .python:
        flags = ["-c"]
    case .node:
        flags = ["-e", "--eval", "-p", "--print"]
    case .ruby:
        flags = ["-e"]
    default:
        return nil
    }
    var index = 1
    while index < tokens.count {
        let token = tokens[index].lexeme
        if flags.contains(token) {
            return .limited(kind)
        }
        if kind == .ruby, token.hasPrefix("-e"), token.hasPrefix("--") == false, token.count > 2 {
            return .limited(kind)
        }
        if kind == .node, token.hasPrefix("--eval=") || token.hasPrefix("--print=") {
            return .limited(kind)
        }
        index += 1
    }
    return nil
}

private func peelStdinExecuting(
    consumer: String,
    producer: String?,
    heredocBody: String?,
    cwd: WorkingDirectory?
) -> Peel? {
    let tokens = ShellPipeline.tokenize(consumer)
    guard let first = tokens.first else { return nil }
    let head = basename(first.lexeme).lowercased()
    guard let kind = sinkKind(head) else { return nil }

    let processSub = extractProcessSub(consumer)
    var index = 1
    var unmodeled = false
    var sawStdinOperand = false
    var sawScriptFile = false

    while index < tokens.count {
        let token = tokens[index].lexeme
        if token.hasPrefix("<(") || token.hasPrefix("<<") {
            break
        }
        if token == "--" {
            index += 1
            if index < tokens.count {
                classifyOperand(tokens[index].lexeme, sawStdinOperand: &sawStdinOperand, sawScriptFile: &sawScriptFile)
            }
            break
        }
        if isSinkArgFlag(token, kind: kind) {
            guard index + 1 < tokens.count else {
                unmodeled = true
                break
            }
            index += 2
            continue
        }
        if attachedSinkArg(token, kind: kind) != nil {
            index += 1
            continue
        }
        if isSinkFlag(token, kind: kind) || isClusteredSinkShort(token, kind: kind) {
            index += 1
            continue
        }
        if token.hasPrefix("-"), token != "-" {
            unmodeled = true
            break
        }
        classifyOperand(token, sawStdinOperand: &sawStdinOperand, sawScriptFile: &sawScriptFile)
        break
    }

    let executing =
        producer != nil
        || processSub != nil
        || (heredocBody?.isEmpty == false)
        || sawStdinOperand
    if executing == false {
        return nil
    }
    if unmodeled {
        return .limited(kind)
    }
    if sawScriptFile, processSub == nil, (heredocBody == nil || heredocBody?.isEmpty == true) {
        return .limited(kind)
    }

    if let processSub {
        guard let program = programFromSource(processSub), program.isEmpty == false else {
            return .limited(kind)
        }
        return .next(program, kind, cwd)
    }
    if let heredocBody, heredocBody.isEmpty == false {
        return .next(heredocBody, kind, cwd)
    }
    if let producer, let program = peelProducerProgram(producer) {
        return .next(program, kind, cwd)
    }
    return .limited(kind)
}

private func classifyOperand(
    _ token: String,
    sawStdinOperand: inout Bool,
    sawScriptFile: inout Bool
) {
    if token == "-" || token == "/dev/stdin" || token == "/dev/fd/0" {
        sawStdinOperand = true
    } else {
        sawScriptFile = true
    }
}

private func peelProducerProgram(_ producer: String) -> String? {
    let parts = splitTopLevelPipes(producer)
    guard let first = parts.first, let echoed = peelEchoPrintf(first) else {
        return nil
    }
    if parts.dropFirst().allSatisfy(isDataConsumer) {
        return echoed
    }
    return nil
}

private func programFromSource(_ source: String) -> String? {
    peelEchoPrintf(source.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func peelEchoPrintf(_ text: String) -> String? {
    let tokens = ShellPipeline.tokenize(text)
    guard let first = tokens.first else { return nil }
    let head = basename(first.lexeme).lowercased()
    guard head == "echo" || head == "printf" else { return nil }
    var index = 1
    var args: [String] = []
    while index < tokens.count {
        let token = tokens[index]
        if token.wasAnsiC { return nil }
        if token.lexeme.contains("$") || token.lexeme.contains("`") { return nil }
        let decoded = token.lexeme
        if args.isEmpty, head == "echo" {
            if decoded == "--" {
                index += 1
                continue
            }
            if isEchoOption(decoded) {
                index += 1
                continue
            }
        }
        args.append(decoded)
        index += 1
    }
    if head == "printf", let format = args.first, format.contains("%") {
        args.removeFirst()
    }
    if args.isEmpty { return nil }
    return args.joined(separator: " ")
}

private func isEchoOption(_ token: String) -> Bool {
    if token == "-n" || token == "-e" || token == "-E" {
        return true
    }
    guard token.hasPrefix("-"), token.hasPrefix("--") == false, token != "-" else {
        return false
    }
    return token.dropFirst().allSatisfy { $0 == "n" || $0 == "e" || $0 == "E" }
}

private func lastExecutingSinkIndex(_ pipes: [String]) -> Int? {
    for index in pipes.indices.reversed() {
        if isDataConsumer(pipes[index]) {
            continue
        }
        return index
    }
    return nil
}

private func isDataConsumer(_ consumer: String) -> Bool {
    let tokens = ShellPipeline.tokenize(consumer)
    guard let first = tokens.first else { return false }
    switch basename(first.lexeme).lowercased() {
    case "grep", "rg", "ripgrep", "wc", "tee", "sort", "uniq", "head", "tail", "less", "more", "cat":
        return true
    default:
        return false
    }
}

private func sinkKind(_ head: String) -> WrapperKind? {
    switch head {
    case "bash":
        return .bash
    case "sh":
        return .sh
    case "zsh":
        return .zsh
    default:
        if isPythonExecutable(head) { return .python }
        if isNodeExecutable(head) { return .node }
        if isRubyExecutable(head) { return .ruby }
        return nil
    }
}

private let shellLongFlags: Set<String> = [
    "--norc", "--noprofile", "--restricted", "--posix", "--login",
    "--verbose", "--debugger", "--noediting", "--pretty-print",
    "--help", "--version", "--dump-po-strings", "--dump-strings",
]
private let shellArgFlags: Set<String> = [
    "--init-file", "--rcfile", "-o", "-O",
]
private let shellShortLetters: Set<Character> = [
    "a", "b", "e", "f", "h", "i", "k", "l", "m", "n", "p", "r", "s",
    "t", "u", "v", "x", "B", "C", "E", "H", "P", "T", "D",
]
private let pythonFlags: Set<String> = [
    "-u", "-B", "-E", "-I", "-O", "-S", "-s", "-v", "-q", "-b", "-P",
]
private let pythonArgFlags: Set<String> = ["-X", "-W"]
private let nodeFlags: Set<String> = [
    "--abort-on-uncaught-exception", "--no-warnings", "--trace-warnings",
]
private let nodeArgFlags: Set<String> = ["--input-type", "--title"]
private let rubyFlags: Set<String> = ["-v", "-w", "-W0", "-W1", "-W2"]
private let rubyArgFlags: Set<String> = ["-I", "-r", "-C"]

private func isSinkFlag(_ token: String, kind: WrapperKind) -> Bool {
    switch kind {
    case .bash, .sh, .zsh:
        return shellLongFlags.contains(token)
    case .python:
        return pythonFlags.contains(token)
    case .node:
        return nodeFlags.contains(token)
    case .ruby:
        return rubyFlags.contains(token)
    default:
        return false
    }
}

private func isSinkArgFlag(_ token: String, kind: WrapperKind) -> Bool {
    switch kind {
    case .bash, .sh, .zsh:
        return shellArgFlags.contains(token)
    case .python:
        return pythonArgFlags.contains(token)
    case .node:
        return nodeArgFlags.contains(token)
    case .ruby:
        return rubyArgFlags.contains(token)
    default:
        return false
    }
}

private func attachedSinkArg(_ token: String, kind: WrapperKind) -> String? {
    let longs: [String]
    switch kind {
    case .bash, .sh, .zsh:
        longs = ["--init-file", "--rcfile"]
    case .node:
        longs = ["--input-type", "--title"]
    default:
        longs = []
    }
    for long in longs {
        if let value = attachedOptionValue(token, long: long) {
            return value
        }
    }
    return nil
}

private func isClusteredSinkShort(_ token: String, kind: WrapperKind) -> Bool {
    guard kind == .bash || kind == .sh || kind == .zsh else { return false }
    guard token.hasPrefix("-"), token.hasPrefix("--") == false, token != "-" else {
        return false
    }
    let letters = token.dropFirst()
    if letters.isEmpty { return false }
    if letters.contains("c") { return false }
    return letters.allSatisfy { shellShortLetters.contains($0) }
}

private func splitTopLevelPipes(_ text: String) -> [String] {
    var segments: [String] = []
    var current = ""
    var quote: Character?
    var parenDepth = 0
    var inBacktick = false
    var index = text.startIndex

    func flush() {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            segments.append(trimmed)
        }
        current = ""
    }

    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        if let currentQuote = quote {
            current.append(character)
            if character == currentQuote {
                quote = nil
            }
            index = next
            continue
        }
        if inBacktick {
            current.append(character)
            if character == "`" {
                inBacktick = false
            }
            index = next
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            current.append(character)
            index = next
            continue
        }
        if character == "`" {
            inBacktick = true
            current.append(character)
            index = next
            continue
        }
        if (character == "<" || character == ">" || character == "$"),
            next < text.endIndex, text[next] == "("
        {
            parenDepth += 1
            current.append(character)
            current.append("(")
            index = text.index(after: next)
            continue
        }
        if character == "(" {
            parenDepth += 1
            current.append(character)
            index = next
            continue
        }
        if character == ")" {
            if parenDepth > 0 {
                parenDepth -= 1
            }
            current.append(character)
            index = next
            continue
        }
        if parenDepth == 0, character == "|" {
            if next < text.endIndex, text[next] == "|" {
                current.append(character)
                current.append("|")
                index = text.index(after: next)
                continue
            }
            flush()
            index = next
            continue
        }
        current.append(character)
        index = next
    }
    flush()
    return segments
}

private func extractProcessSub(_ text: String) -> String? {
    var quote: Character?
    var inBacktick = false
    var index = text.startIndex
    var start: String.Index?
    var depth = 0

    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        if start == nil {
            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
                index = next
                continue
            }
            if inBacktick {
                if character == "`" {
                    inBacktick = false
                }
                index = next
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = next
                continue
            }
            if character == "`" {
                inBacktick = true
                index = next
                continue
            }
            if character == "<", next < text.endIndex, text[next] == "(" {
                start = text.index(after: next)
                depth = 1
                index = text.index(after: next)
                continue
            }
            index = next
            continue
        }

        if let currentQuote = quote {
            if character == currentQuote {
                quote = nil
            }
            index = next
            continue
        }
        if inBacktick {
            if character == "`" {
                inBacktick = false
            }
            index = next
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            index = next
            continue
        }
        if character == "`" {
            inBacktick = true
            index = next
            continue
        }
        if (character == "<" || character == ">" || character == "$"),
            next < text.endIndex, text[next] == "("
        {
            depth += 1
            index = text.index(after: next)
            continue
        }
        if character == "(" {
            depth += 1
            index = next
            continue
        }
        if character == ")" {
            depth -= 1
            if depth == 0, let start {
                return String(text[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            index = next
            continue
        }
        index = next
    }
    return nil
}

func extractHeredoc(_ text: String) -> (header: String, body: String)? {
    var quote: Character?
    var parenDepth = 0
    var inBacktick = false
    var index = text.startIndex

    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        if let currentQuote = quote {
            if character == currentQuote {
                quote = nil
            }
            index = next
            continue
        }
        if inBacktick {
            if character == "`" {
                inBacktick = false
            }
            index = next
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            index = next
            continue
        }
        if character == "`" {
            inBacktick = true
            index = next
            continue
        }
        if (character == "<" || character == ">" || character == "$"),
            next < text.endIndex, text[next] == "("
        {
            parenDepth += 1
            index = text.index(after: next)
            continue
        }
        if character == "(" {
            parenDepth += 1
            index = next
            continue
        }
        if character == ")" {
            if parenDepth > 0 {
                parenDepth -= 1
            }
            index = next
            continue
        }
        if parenDepth == 0, character == "<", next < text.endIndex, text[next] == "<" {
            let afterTwo = text.index(after: next)
            if afterTwo < text.endIndex, text[afterTwo] == "<" {
                index = text.index(after: afterTwo)
                continue
            }
            if let parsed = parseHeredoc(in: text, afterOperator: afterTwo) {
                return parsed
            }
            index = afterTwo
            continue
        }
        index = next
    }
    return nil
}

private func parseHeredoc(
    in text: String,
    afterOperator: String.Index
) -> (header: String, body: String)? {
    var cursor = afterOperator
    var stripTabs = false
    if cursor < text.endIndex, text[cursor] == "-" {
        stripTabs = true
        cursor = text.index(after: cursor)
    }
    while cursor < text.endIndex, text[cursor].isWhitespace, text[cursor] != "\n" {
        cursor = text.index(after: cursor)
    }
    guard cursor < text.endIndex, text[cursor] != "\n" else { return nil }

    let delimiter: String
    if text[cursor] == "'" || text[cursor] == "\"" {
        let quote = text[cursor]
        cursor = text.index(after: cursor)
        let start = cursor
        while cursor < text.endIndex, text[cursor] != quote {
            cursor = text.index(after: cursor)
        }
        delimiter = String(text[start..<cursor])
        if cursor < text.endIndex {
            cursor = text.index(after: cursor)
        }
    } else {
        let start = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == "|" || character == "<"
                || character == ">" || character == ";" || character == "&"
                || character == "(" || character == ")"
            {
                break
            }
            cursor = text.index(after: cursor)
        }
        delimiter = String(text[start..<cursor])
    }
    if delimiter.isEmpty { return nil }

    var lineEnd = cursor
    while lineEnd < text.endIndex, text[lineEnd] != "\n" {
        lineEnd = text.index(after: lineEnd)
    }
    guard lineEnd < text.endIndex else { return nil }
    let header = String(text[text.startIndex..<lineEnd])
    let bodyStart = text.index(after: lineEnd)
    let body = heredocBody(
        String(text[bodyStart...]),
        delimiter: delimiter,
        stripTabs: stripTabs
    )
    return (header, body)
}

private func heredocBody(_ rest: String, delimiter: String, stripTabs: Bool) -> String {
    var lines: [String] = []
    var remaining = rest[...]
    while remaining.isEmpty == false {
        let line: Substring
        if let newline = remaining.firstIndex(of: "\n") {
            line = remaining[..<newline]
            remaining = remaining[remaining.index(after: newline)...]
        } else {
            line = remaining
            remaining = remaining[remaining.endIndex...]
        }
        let compared = stripTabs ? String(line.drop(while: { $0 == "\t" })) : String(line)
        if compared == delimiter {
            break
        }
        lines.append(String(line))
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

import Foundation
import RVDomain

// Part of the single recursive unwrap; see `Unwrap.swift` for the
// recursion, budget, and `peel` dispatch.

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
    let head = unescapeBackslashPairs(basename(first.lexeme)).lowercased()
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
    _ tokens: [ShellPipeline.Token],
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
                ShellPipeline.Token(lexeme: value, wasQuoted: tokens[index].wasQuoted),
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

private func peelInterpreterProgramFlag(_ tokens: [ShellPipeline.Token], kind: WrapperKind) -> Peel? {
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
    let head = unescapeBackslashPairs(basename(first.lexeme)).lowercased()
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
    let head = unescapeBackslashPairs(basename(first.lexeme)).lowercased()
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
    switch unescapeBackslashPairs(basename(first.lexeme)).lowercased() {
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

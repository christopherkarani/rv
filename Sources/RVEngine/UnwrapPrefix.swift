import RVDomain

func peelTimeout(_ tokens: [CommandToken], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].decoded
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
        if attachedLongValue(token, long: "--kill-after") != nil
            || attachedLongValue(token, long: "--signal") != nil
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
    guard looksLikeTimeoutDuration(tokens[index].decoded) else {
        return .limited(.timeout)
    }
    index += 1
    let rest = Array(tokens.dropFirst(index))
    if rest.isEmpty { return .limited(.timeout) }
    return .next(renderCommand(rest), .timeout, workingDirectory)
}

func peelNice(_ tokens: [CommandToken], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    var sawOption = false
    while index < tokens.count {
        let token = tokens[index].decoded
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
        if attachedLongValue(token, long: "--adjustment") != nil {
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

func peelMise(_ tokens: [CommandToken], workingDirectory: WorkingDirectory?) -> Peel {
    guard tokens.count >= 2 else { return .notWrapper }
    let subcommand = tokens[1].decoded.lowercased()
    guard subcommand == "exec" || subcommand == "x" else { return .notWrapper }
    let index = 2
    while index < tokens.count {
        let token = tokens[index].decoded
        if token == "--" {
            let rest = Array(tokens.dropFirst(index + 1))
            if rest.isEmpty { return .limited(.mise) }
            return .next(renderCommand(rest), .mise, workingDirectory)
        }
        if token == "-c" || token == "--command" {
            guard index + 1 < tokens.count else { return .limited(.mise) }
            return peelShellPayload(tokens[index + 1], kind: .mise, cwd: workingDirectory)
        }
        if let value = attachedLongValue(token, long: "--command") {
            return peelShellPayload(
                CommandToken(decoded: value, wasQuoted: tokens[index].wasQuoted),
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

private func attachedLongValue(_ token: String, long: String) -> String? {
    let prefix = long + "="
    guard token.hasPrefix(prefix) else { return nil }
    let value = String(token.dropFirst(prefix.count))
    return value.isEmpty ? nil : value
}

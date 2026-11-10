import Foundation
import RVDomain

// Part of the single recursive unwrap; see `Unwrap.swift` for the
// recursion, budget, and `peel` dispatch.

func peelSudo(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
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
            // A chroot (`-R`) or a cluster ending in a directory changes
            // what every path means.
            if shortClusterConsumesValue(token, valueLetters: ["D", "R"]) {
                return .limited(.sudo)
            }
            if shortClusterConsumesValue(token, valueLetters: sudoShortArgLetters) {
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

private let sudoShortArgLetters: Set<Character> = ["u", "g", "h", "p", "C", "U", "T", "r", "t", "c", "a"]
private let sudoLongArgFlags: Set<String> = [
    "--user", "--group", "--host", "--prompt", "--close-from", "--chdir",
    "--other-user", "--command-timeout",
]
private let sudoLongFlags: Set<String> = [
    "--preserve-env", "--login", "--shell", "--non-interactive", "--set-home",
    "--reset-timestamp", "--askpass", "--background", "--preserve-groups",
    "--stdin", "--help", "--version",
]

func peelEnv(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    var cwd = workingDirectory
    while index < tokens.count {
        let token = tokens[index].lexeme
        if token.hasPrefix("-") {
            switch envOptionShape(token) {
            case .unknown, .splitString:
                return .limited(.env)
            case .flag:
                index += 1
            case .chdirAttached(let value):
                cwd = resolveWorkingDirectory(value, current: cwd)
                index += 1
            case .valueNext(let chdir):
                guard index + 1 < tokens.count else { return .limited(.env) }
                if chdir {
                    cwd = resolveWorkingDirectory(tokens[index + 1].lexeme, current: cwd)
                }
                index += 2
            }
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

func peelCommandWrapper(
    _ tokens: [ShellPipeline.Token],
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

func peelTimeout(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
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

func peelNice(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
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

func peelMise(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
    guard tokens.count >= 2 else { return .notWrapper }
    let subcommand = tokens[1].lexeme.lowercased()
    guard subcommand == "exec" || subcommand == "x" else { return .notWrapper }
    let index = 2
    if index < tokens.count {
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
                ShellPipeline.Token(lexeme: value, wasQuoted: tokens[index].wasQuoted),
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

func peelSSH(_ tokens: [ShellPipeline.Token], workingDirectory: WorkingDirectory?) -> Peel {
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

private enum SSHOptionParse: Sendable {
    case consumed(Int)
    case unknown
    case missingArgument
}

private func consumeSSHOption(_ tokens: [ShellPipeline.Token], at index: Int) -> SSHOptionParse {
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

import RVDomain

func peelSSH(_ tokens: [CommandToken], workingDirectory: WorkingDirectory?) -> Peel {
    var index = 1
    while index < tokens.count {
        let token = tokens[index].decoded
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
        if token.wasQuoted, token.decoded.contains("$") || token.decoded.contains("`") {
            return .limited(.ssh)
        }
    }
    if rest.count == 1 {
        return .next(rest[0].decoded, .ssh, workingDirectory)
    }
    return .next(renderCommand(rest), .ssh, workingDirectory)
}

private enum SSHOptionParse {
    case consumed(Int)
    case unknown
    case missingArgument
}

private func consumeSSHOption(_ tokens: [CommandToken], at index: Int) -> SSHOptionParse {
    let token = tokens[index].decoded
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

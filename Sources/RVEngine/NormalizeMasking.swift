func isAllArgsData(_ command: String?) -> Bool {
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

func isGitGlobalValueFlag(_ flag: String) -> Bool {
    flag == "-C" || flag == "-c"
        || flag == "--git-dir" || flag == "--work-tree"
        || flag == "--namespace" || flag == "--config-env"
}

func isGitGlobalAttachedFlag(_ flag: String) -> Bool {
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

func isDataConsumingFlag(command: String?, gitSubcommand: String?, flag: String) -> Bool {
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

func maskAttachedDataValue(
    command: String?,
    gitSubcommand: String?,
    token: CommandToken
) -> String? {
    let decoded = token.decoded
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

func isGitGrepPatternFileFlag(_ flag: String) -> Bool {
    flag == "-f" || flag == "--file" || flag.hasPrefix("--file=")
}

func shouldMaskQuotedData(
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

func isGitConfigValueFlag(_ flag: String) -> Bool {
    flag == "--file" || flag.hasPrefix("--file=")
        || flag == "-f"
        || flag == "--blob" || flag.hasPrefix("--blob=")
        || flag == "--default" || flag.hasPrefix("--default=")
        || flag == "--type" || flag.hasPrefix("--type=")
}

func maskGitConfigAssignment(_ decoded: String) -> String? {
    guard let equals = decoded.firstIndex(of: "=") else { return nil }
    let prefix = String(decoded[...equals])
    let valueCount = decoded.distance(from: decoded.index(after: equals), to: decoded.endIndex)
    return prefix + String(repeating: " ", count: max(valueCount, 1))
}

import RVDomain

/// Pure Git classifier. Unknown or unsupported syntax is `.unknown`.
public func analyzeGit(
    _ command: ShellCommand,
    context: GitAnalysisContext = .empty
) -> SemanticAnalysis {
    let view = Normalize.matchingView(of: command).rawValue
    if view.isEmpty { return .unknown }
    if splitSegments(view).count > 1 { return .unknown }
    let tokens = tokenizeCommand(view).map(\.decoded)
    guard let parsed = parseGitInvocation(tokens, context: context) else {
        return .unknown
    }
    return .git(parsed)
}

private func parseGitInvocation(
    _ tokens: [String],
    context: GitAnalysisContext
) -> GitAction? {
    guard let first = tokens.first, basename(first).lowercased() == "git" else {
        return nil
    }
    for token in tokens {
        if isDynamicToken(token) { return nil }
    }

    var index = 1
    while index < tokens.count {
        let token = tokens[index]
        if token == "--" {
            index += 1
            break
        }
        if token.hasPrefix("-") == false {
            break
        }
        guard let consumed = consumeGitGlobal(tokens, at: index) else {
            return nil
        }
        index = consumed
    }
    guard index < tokens.count else { return nil }
    let subcommand = tokens[index].lowercased()
    let args = Array(tokens[(index + 1)...])
    switch subcommand {
    case "checkout":
        return parseCheckout(args)
    case "switch":
        return parseSwitch(args)
    case "restore":
        return parseRestore(args)
    case "reset":
        return parseReset(args)
    case "clean":
        return parseClean(args)
    case "push":
        return parsePush(args, context: context)
    case "branch":
        return parseBranch(args)
    case "tag":
        return parseTag(args)
    case "stash":
        return parseStash(args)
    case "rebase":
        return parseRebase(args)
    default:
        return nil
    }
}

private func consumeGitGlobal(_ tokens: [String], at index: Int) -> Int? {
    let token = tokens[index]
    if gitGlobalFlags.contains(token) {
        return index + 1
    }
    if let prefix = gitGlobalEqualsPrefixes.first(where: { token.hasPrefix($0) }) {
        if token == prefix {
            guard index + 1 < tokens.count, tokens[index + 1].hasPrefix("-") == false else {
                return token == "--exec-path" ? index + 1 : nil
            }
            return index + 2
        }
        if token.hasPrefix(prefix) { return index + 1 }
    }
    if token == "-C" || token == "-c" {
        guard index + 1 < tokens.count else { return nil }
        return index + 2
    }
    return nil
}

private let gitGlobalFlags: Set<String> = [
    "-v", "--version", "-h", "--help",
    "-p", "--paginate", "-P", "--no-pager",
    "--no-replace-objects", "--no-lazy-fetch", "--no-optional-locks",
    "--no-advice", "--bare",
    "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs",
    "--icase-pathspecs",
]

private let gitGlobalEqualsPrefixes = [
    "--exec-path", "--git-dir", "--work-tree", "--namespace",
    "--config-env", "--super-prefix", "--list-cmds", "--attr-source",
]

private func isDynamicToken(_ token: String) -> Bool {
    token.contains("$") || token.contains("`")
}

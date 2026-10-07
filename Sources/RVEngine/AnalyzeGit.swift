import RVDomain

/// Pure Git classifier. Unknown or unsupported syntax is `.unknown`.
public func analyzeGit(
    _ command: ExecutingCommand,
    context: GitAnalysisContext = .empty
) -> SemanticAnalysis {
    let view = Normalize.matchingView(of: command.rawValue).rawValue
    if view.isEmpty { return .unknown }
    guard let single = singleEffectiveSegment(view) else { return .unknown }
    let tokens = tokenizeCommand(single).map(\.decoded)
    guard let parsed = parseGitInvocation(tokens, context: context) else {
        return .unknown
    }
    return .git(parsed)
}

public func analyzeGit(
    _ command: ShellCommand,
    context: GitAnalysisContext = .empty
) -> SemanticAnalysis {
    analyzeGit(ExecutingCommand(rawValue: command.rawValue), context: context)
}

/// Parses every chain segment as a git invocation, in order. Unparseable
/// (non-git, dynamic, unknown-syntax) segments are skipped: pack patterns
/// still cover the full text, and the policy stage evaluates each parsed
/// action. Used by the apply stage so a benign prefix cannot hide a risky
/// later segment (Step 8B §24).
func parseGitSegments(
    _ view: String,
    context: GitAnalysisContext
) -> [GitAction] {
    splitSegments(view).flatMap { splitSegments(ShellPipeline.stripLeadingAssignmentPrefixes($0)) }
        .compactMap { segment in
            parseGitInvocation(tokenizeCommand(segment).map(\.decoded), context: context)
        }
}

private func parseGitInvocation(
    _ tokens: [String],
    context: GitAnalysisContext
) -> GitAction? {
    guard let first = tokens.first,
        unescapeBackslashPairs(basename(first)).lowercased() == "git"
    else {
        return nil
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
    if subcommand == "push" {
        // Push is authority-expanding with no allow arm: a recognized
        // push verb that fails to parse fails closed as an unproven
        // remote mutation (unknown flags, extra positionals, dynamic
        // tokens, trailing words). Dry-run stays unparsed — preview
        // sends nothing, so the pack floor governs (textual force
        // patterns still deny).
        if let push = parsePush(args, context: context) {
            return push
        }
        if pushArgsAreDryRun(args) {
            return nil
        }
        return .pushUnparsed(args: args)
    }
    for token in tokens {
        if isDynamicToken(token) { return nil }
    }
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

import RVDomain

/// Pure Git classifier. Unknown or unsupported syntax is `.unknown`.
public func analyzeGit(
    _ command: ShellCommand,
    context: GitAnalysisContext = .empty
) -> SemanticAnalysis {
    let view = Normalize.matchingView(of: command.rawValue).rawValue
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

private func parseCheckout(_ args: [String]) -> GitAction? {
    var create = false
    var forceCreate = false
    var orphan = false
    var force = false
    var pendingName = false
    var before: [String] = []
    var after: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if pendingName {
            if token.hasPrefix("-") { return nil }
            before.append(token)
            pendingName = false
            index += 1
            continue
        }
        if seenDash {
            after.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if token == "-b" || token == "--branch" {
            create = true
            pendingName = true
            index += 1
            continue
        }
        if token == "-B" {
            forceCreate = true
            pendingName = true
            index += 1
            continue
        }
        if token == "--orphan" {
            orphan = true
            pendingName = true
            index += 1
            continue
        }
        if let name = attachedValue(token, long: "--branch") {
            create = true
            before.append(name)
            index += 1
            continue
        }
        if token == "-f" || token == "--force" {
            force = true
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "q", "l", "t", "m":
                    continue
                case "f":
                    force = true
                case "b":
                    create = true
                    pendingName = true
                case "B":
                    forceCreate = true
                    pendingName = true
                case "p":
                    return nil
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if checkoutSkipFlags.contains(token) {
            index += 1
            continue
        }
        if token.hasPrefix("--conflict=") {
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        before.append(token)
        index += 1
    }
    if pendingName { return nil }
    if create || forceCreate || orphan {
        if seenDash && after.isEmpty == false { return nil }
        guard let name = before.first else { return nil }
        if before.count > 2 { return nil }
        return .createBranch(
            name: name,
            startPoint: before.count > 1 ? before[1] : nil,
            force: forceCreate
        )
    }
    if seenDash {
        return .discardWorktree(pathspecs: after, source: before.first)
    }
    if force, let name = before.first, before.count == 1, after.isEmpty {
        return .switchBranch(name: name, force: true)
    }
    return nil
}

private let checkoutSkipFlags: Set<String> = [
    "-q", "--quiet", "--track", "--no-track", "-t", "-l",
    "--detach", "--progress", "--no-progress",
    "--ignore-other-worktrees", "--guess", "--no-guess",
    "--recurse-submodules", "--no-recurse-submodules",
    "--overlay", "--no-overlay", "--overwrite-ignore", "--no-overwrite-ignore",
    "--ignore-skip-worktree-bits", "-m", "--merge",
    "--ours", "--theirs",
]

private func parseSwitch(_ args: [String]) -> GitAction? {
    var create = false
    var forceCreate = false
    var force = false
    var pendingName = false
    var name: String?
    var index = 0
    while index < args.count {
        let token = args[index]
        if pendingName {
            if token.hasPrefix("-") { return nil }
            name = token
            pendingName = false
            index += 1
            continue
        }
        if token == "-c" || token == "--create" {
            create = true
            pendingName = true
            index += 1
            continue
        }
        if token == "-C" || token == "--force-create" {
            forceCreate = true
            pendingName = true
            index += 1
            continue
        }
        if token == "-f" || token == "--force" || token == "--discard-changes" {
            force = true
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "q", "d", "m", "t":
                    continue
                case "f":
                    force = true
                case "c":
                    create = true
                    pendingName = true
                case "C":
                    forceCreate = true
                    pendingName = true
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if switchSkipFlags.contains(token) {
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        if name != nil { return nil }
        name = token
        index += 1
    }
    if pendingName { return nil }
    guard let name else { return nil }
    if create || forceCreate {
        return .createBranch(name: name, startPoint: nil, force: forceCreate)
    }
    return .switchBranch(name: name, force: force)
}

private let switchSkipFlags: Set<String> = [
    "-q", "--quiet", "-d", "--detach", "--guess", "--no-guess",
    "--track", "--no-track", "-t", "-m", "--merge",
    "--ignore-other-worktrees", "--recurse-submodules", "--no-recurse-submodules",
]

private func parseRestore(_ args: [String]) -> GitAction? {
    var staged = false
    var worktree = false
    var source: String?
    var pathspecs: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            pathspecs.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if token == "--staged" || token == "-S" {
            staged = true
            index += 1
            continue
        }
        if token == "--worktree" || token == "-W" {
            worktree = true
            index += 1
            continue
        }
        if token == "--source" {
            guard index + 1 < args.count else { return nil }
            source = args[index + 1]
            index += 2
            continue
        }
        if let value = attachedValue(token, long: "--source") {
            source = value
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "S":
                    staged = true
                case "W":
                    worktree = true
                case "q":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if restoreSkipFlags.contains(token) {
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        pathspecs.append(token)
        index += 1
    }
    if staged == false && worktree == false {
        worktree = true
    }
    return .restore(pathspecs: pathspecs, staged: staged, worktree: worktree, source: source)
}

private let restoreSkipFlags: Set<String> = [
    "-q", "--quiet", "--progress", "--no-progress", "--ours", "--theirs",
    "--merge", "-m", "--ignore-unmerged", "--ignore-skip-worktree-bits",
    "--overlay", "--no-overlay",
]

private func parseReset(_ args: [String]) -> GitAction? {
    var mode: GitResetMode = .mixed
    var sawMode = false
    var target: String?
    var seenDash = false
    var pathspecs: [String] = []
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            pathspecs.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if token == "--hard" {
            if sawMode { return nil }
            mode = .hard
            sawMode = true
            index += 1
            continue
        }
        if token == "--soft" {
            if sawMode { return nil }
            mode = .soft
            sawMode = true
            index += 1
            continue
        }
        if token == "--mixed" {
            if sawMode { return nil }
            mode = .mixed
            sawMode = true
            index += 1
            continue
        }
        if token == "--merge" {
            if sawMode { return nil }
            mode = .merge
            sawMode = true
            index += 1
            continue
        }
        if token == "--keep" {
            if sawMode { return nil }
            mode = .keep
            sawMode = true
            index += 1
            continue
        }
        if token == "-q" || token == "--quiet" || token == "-N" || token == "--intent-to-add" {
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        if target != nil { return nil }
        target = token
        index += 1
    }
    if pathspecs.isEmpty == false {
        if mode == .hard {
            return .discardWorktree(pathspecs: pathspecs, source: target)
        }
        return nil
    }
    return .reset(mode: mode, target: target)
}

private func parseClean(_ args: [String]) -> GitAction? {
    var force = false
    var dryRun = false
    var directories = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if token == "--force" {
            force = true
            index += 1
            continue
        }
        if token == "--dry-run" {
            dryRun = true
            index += 1
            continue
        }
        if token == "-d" {
            directories = true
            index += 1
            continue
        }
        if token == "-e" || token == "--exclude" {
            guard index + 1 < args.count else { return nil }
            index += 2
            continue
        }
        if token == "-q" || token == "--quiet" || token == "-x" || token == "-X" {
            index += 1
            continue
        }
        if token == "-i" || token == "--interactive" {
            return nil
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "f":
                    force = true
                case "n":
                    dryRun = true
                case "d":
                    directories = true
                case "q", "x", "X":
                    continue
                case "i":
                    return nil
                case "e":
                    return nil
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token == "--" {
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        index += 1
    }
    return .clean(force: force, dryRun: dryRun, directories: directories)
}

private func parsePush(_ args: [String], context: GitAnalysisContext) -> GitAction? {
    var force = GitPushForce.none
    var delete = false
    var positionals: [String] = []
    var index = 0
    while index < args.count {
        let token = args[index]
        if token == "--force" {
            force = .force
            index += 1
            continue
        }
        if token == "--force-with-lease" || token.hasPrefix("--force-with-lease=")
            || token == "--force-if-includes"
        {
            if force != .force { force = .forceWithLease }
            index += 1
            continue
        }
        if token == "--delete" || token == "-d" {
            delete = true
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "f":
                    force = .force
                case "d":
                    delete = true
                case "u", "q", "v", "n":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if pushSkipFlags.contains(token) {
            index += 1
            continue
        }
        if token == "--repo" || token.hasPrefix("--repo=") {
            if token == "--repo" {
                guard index + 1 < args.count else { return nil }
                index += 2
            } else {
                index += 1
            }
            continue
        }
        if token.hasPrefix("-") { return nil }
        positionals.append(token)
        index += 1
    }
    let remote = positionals.first
    var refspec = positionals.count > 1 ? positionals[1] : context.currentBranch
    if positionals.count > 2 { return nil }
    if let spec = refspec, spec.hasPrefix(":") {
        delete = true
        if spec.count > 1 {
            refspec = String(spec.dropFirst())
        }
    }
    return .push(remote: remote, refspec: refspec, force: force, delete: delete)
}

private let pushSkipFlags: Set<String> = [
    "-u", "--set-upstream", "--all", "--mirror", "--tags", "--follow-tags",
    "-q", "--quiet", "-v", "--verbose", "-n", "--dry-run", "--prune",
    "--no-verify", "--verify", "--atomic", "--no-atomic",
    "--progress", "--no-progress", "--ipv4", "--ipv6", "-4", "-6",
]

private func parseBranch(_ args: [String]) -> GitAction? {
    var delete = false
    var force = false
    var names: [String] = []
    var index = 0
    while index < args.count {
        let token = args[index]
        if token == "--delete" || token == "-d" {
            delete = true
            index += 1
            continue
        }
        if token == "-D" {
            delete = true
            force = true
            index += 1
            continue
        }
        if token == "--force" || token == "-f" {
            force = true
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "d":
                    delete = true
                case "D":
                    delete = true
                    force = true
                case "f":
                    force = true
                case "q", "v", "a", "r", "t":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if branchSkipFlags.contains(token) {
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        names.append(token)
        index += 1
    }
    guard delete, let name = names.first, names.count == 1 else { return nil }
    return .deleteBranch(name: name, force: force, remote: false)
}

private let branchSkipFlags: Set<String> = [
    "-q", "--quiet", "-v", "--verbose", "-a", "--all", "-r", "--remotes",
    "--list", "-l", "--track", "--no-track",
]

private func parseTag(_ args: [String]) -> GitAction? {
    var delete = false
    var names: [String] = []
    var index = 0
    while index < args.count {
        let token = args[index]
        if token == "--delete" || token == "-d" {
            delete = true
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "d":
                    delete = true
                case "l", "n", "f", "a", "s", "u", "m", "F", "e":
                    return nil
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        names.append(token)
        index += 1
    }
    guard delete, let name = names.first, names.count == 1 else { return nil }
    return .deleteTag(name: name, remote: nil)
}

private func parseStash(_ args: [String]) -> GitAction? {
    var verb: GitStashVerb?
    var index = 0
    while index < args.count {
        let token = args[index]
        if token.hasPrefix("-") {
            if token == "-m" || token == "--message" {
                guard index + 1 < args.count else { return nil }
                index += 2
                continue
            }
            if stashSkipFlags.contains(token) || token.hasPrefix("--message=") {
                index += 1
                continue
            }
            return nil
        }
        if verb == nil {
            guard let parsed = GitStashVerb(rawValue: token) else { return nil }
            verb = parsed
            index += 1
            continue
        }
        index += 1
    }
    return .stash(verb: verb ?? .push)
}

private let stashSkipFlags: Set<String> = [
    "-u", "--include-untracked", "-a", "--all", "-k", "--keep-index",
    "-q", "--quiet", "--index",
]

private func parseRebase(_ args: [String]) -> GitAction? {
    var verb = GitRebaseVerb.start
    var onto: String?
    var index = 0
    while index < args.count {
        let token = args[index]
        if token == "--abort" {
            verb = .abort
            index += 1
            continue
        }
        if token == "--continue" {
            verb = .continueRebase
            index += 1
            continue
        }
        if token == "--skip" {
            verb = .skip
            index += 1
            continue
        }
        if token == "--onto" {
            guard index + 1 < args.count else { return nil }
            onto = args[index + 1]
            index += 2
            continue
        }
        if token == "-i" || token == "--interactive" || token == "--edit-todo" {
            return nil
        }
        if rebaseSkipFlags.contains(token) {
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        if onto == nil { onto = token }
        index += 1
    }
    return .rebase(verb: verb, onto: onto)
}

private let rebaseSkipFlags: Set<String> = [
    "-q", "--quiet", "--autostash", "--no-autostash",
    "--keep-empty", "--rebase-merges", "--no-keep-empty",
    "--apply", "--merge",
]

private func clusteredShorts(_ token: String) -> [Character]? {
    guard token.hasPrefix("-"), token.hasPrefix("--") == false, token.count > 1 else {
        return nil
    }
    if token.contains("=") { return nil }
    return Array(token.dropFirst())
}

private func attachedValue(_ token: String, long: String) -> String? {
    let prefix = long + "="
    guard token.hasPrefix(prefix) else { return nil }
    let value = String(token.dropFirst(prefix.count))
    return value.isEmpty ? nil : value
}

private func isDynamicToken(_ token: String) -> Bool {
    token.contains("$") || token.contains("`")
}

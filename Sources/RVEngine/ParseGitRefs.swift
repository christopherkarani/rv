import RVDomain

func parsePush(_ args: [String], context: GitAnalysisContext) -> GitAction? {
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
    if delete {
        return .deleteRemoteRef(remote: remote, refspec: refspec)
    }
    return .push(remote: remote, refspec: refspec, force: force)
}

private let pushSkipFlags: Set<String> = [
    "-u", "--set-upstream", "--all", "--mirror", "--tags", "--follow-tags",
    "-q", "--quiet", "-v", "--verbose", "-n", "--dry-run", "--prune",
    "--no-verify", "--verify", "--atomic", "--no-atomic",
    "--progress", "--no-progress", "--ipv4", "--ipv6", "-4", "-6",
]

func parseBranch(_ args: [String]) -> GitAction? {
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
    return .deleteBranch(name: name, force: force)
}

private let branchSkipFlags: Set<String> = [
    "-q", "--quiet", "-v", "--verbose", "-a", "--all", "-r", "--remotes",
    "--list", "-l", "--track", "--no-track",
]

func parseTag(_ args: [String]) -> GitAction? {
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

func parseStash(_ args: [String]) -> GitAction? {
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

func parseRebase(_ args: [String]) -> GitAction? {
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

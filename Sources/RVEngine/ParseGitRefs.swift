import RVDomain

// MARK: - Total Argv parsers (C1 T3b2)
//
// push/branch/tag/stash scan `Argv` through the shared flag grammar
// (`ShellPipeline.scanFlags`). rebase classifies each word with `FlagToken`
// plus one pending flag: legacy rejects attached `--onto=x` while consuming
// a bare `--onto` value verbatim, a distinction the value-merging scan
// cannot express. Parsed `GitAction` output is unchanged, including the
// dead skip entries (`-4`/`-6`, `-l`) that legacy rejects via its
// cluster-first ordering.

/// Parses `git push` argv into a push (or remote-ref delete) action.
func parsePush(_ argv: Argv, context: GitAnalysisContext) -> GitAction? {
    var force = GitPushForce.none
    var delete = false
    var positionals: [String] = []
    for token in ShellPipeline.scanFlags(argv, valueSpec: pushFlagValues) {
        switch token {
        case .long("force", nil):
            force = .force
        case .long("force-with-lease", _), .long("force-if-includes", nil):
            if force != .force { force = .forceWithLease }
        case .long("delete", nil):
            delete = true
        case .long("dry-run", nil):
            // Preview only: git sends nothing. Unparsed, so the pack floor
            // governs (textual force patterns still deny).
            return nil
        case .shorts(let letters, _):
            for letter in letters {
                switch letter {
                case "f":
                    force = .force
                case "d":
                    delete = true
                case "n":
                    return nil
                case "u", "q", "v":
                    break
                default:
                    return nil
                }
            }
        case .long("repo", _):
            break
        case .long(let flag, nil) where pushSkipLongs.contains(flag):
            break
        case .positional(let word):
            positionals.append(word)
        default:
            return nil
        }
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

private let pushFlagValues = FlagValueSpec(valueLongs: ["repo"])

/// True when push argv carries a dry-run marker under the SAME flag
/// grammar `parsePush` uses (value consumption included, so
/// `--repo -n` does not read `-n` as dry-run). Disambiguates
/// `parsePush == nil` (preview → pack floor) from unparsed-push
/// (fail closed). Matches `parsePush`'s two dry-run bail arms exactly.
func pushArgsAreDryRun(_ args: [String]) -> Bool {
    let argv = Argv(program: "git", args: args)
    for token in ShellPipeline.scanFlags(argv, valueSpec: pushFlagValues) {
        switch token {
        case .long("dry-run", nil):
            return true
        case .shorts(let letters, _):
            if letters.contains("n") {
                return true
            }
        default:
            break
        }
    }
    return false
}

private let pushSkipLongs: Set<String> = [
    "set-upstream", "all", "mirror", "tags", "follow-tags",
    "quiet", "verbose", "prune",
    "no-verify", "verify", "atomic", "no-atomic",
    "progress", "no-progress", "ipv4", "ipv6",
]

/// Parses `git branch` argv; only the delete form yields an action.
func parseBranch(_ argv: Argv) -> GitAction? {
    var delete = false
    var force = false
    var names: [String] = []
    for token in ShellPipeline.scanFlags(argv) {
        switch token {
        case .long("delete", nil):
            delete = true
        case .long("force", nil):
            force = true
        case .shorts(let letters, _):
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
                    break
                default:
                    return nil
                }
            }
        case .long(let flag, nil) where branchSkipLongs.contains(flag):
            break
        case .positional(let word):
            names.append(word)
        default:
            return nil
        }
    }
    guard delete, let name = names.first, names.count == 1 else { return nil }
    return .deleteBranch(name: name, force: force)
}

private let branchSkipLongs: Set<String> = [
    "quiet", "verbose", "all", "remotes",
    "list", "track", "no-track",
]

/// Parses `git tag` argv; only the delete form yields an action.
func parseTag(_ argv: Argv) -> GitAction? {
    var delete = false
    var names: [String] = []
    for token in ShellPipeline.scanFlags(argv) {
        switch token {
        case .long("delete", nil):
            delete = true
        case .shorts(let letters, _):
            for letter in letters {
                switch letter {
                case "d":
                    delete = true
                default:
                    return nil
                }
            }
        case .positional(let word):
            names.append(word)
        default:
            return nil
        }
    }
    guard delete, let name = names.first, names.count == 1 else { return nil }
    return .deleteTag(name: name, remote: nil)
}

/// Parses `git stash` argv into a stash-verb action (default `.push`).
func parseStash(_ argv: Argv) -> GitAction? {
    var verb: GitStashVerb?
    for token in ShellPipeline.scanFlags(argv, valueSpec: stashFlagValues) {
        switch token {
        case .long("message", _):
            break
        case .long(let flag, nil) where stashSkipLongs.contains(flag):
            break
        case .shorts(let letters, _):
            guard letters.count == 1, let letter = letters.first else { return nil }
            switch letter {
            case "u", "a", "k", "q", "m":
                break
            default:
                return nil
            }
        case .positional(let word):
            if verb == nil {
                guard let parsed = GitStashVerb(rawValue: word) else { return nil }
                verb = parsed
            }
        default:
            return nil
        }
    }
    return .stash(verb: verb ?? .push)
}

private let stashFlagValues = FlagValueSpec(valueShorts: ["m"], valueLongs: ["message"])

private let stashSkipLongs: Set<String> = [
    "include-untracked", "all", "keep-index", "quiet", "index",
]

/// Parses `git rebase` argv; rejects attached `--onto=x` and interactive flags.
func parseRebase(_ argv: Argv) -> GitAction? {
    var verb = GitRebaseVerb.start
    var onto: String?
    var pendingOnto = false
    for word in argv.args {
        if pendingOnto {
            onto = word
            pendingOnto = false
            continue
        }
        switch FlagToken.classify(word) {
        case .long("abort", nil):
            verb = .abort
        case .long("continue", nil):
            verb = .continueRebase
        case .long("skip", nil):
            verb = .skip
        case .long("onto", nil):
            pendingOnto = true
        case .long("onto", _):
            return nil
        case .long("interactive", _), .long("edit-todo", _):
            return nil
        case .shorts(let letters, _):
            guard letters.count == 1, letters.first == "q" else { return nil }
        case .long(let flag, nil) where rebaseSkipLongs.contains(flag):
            break
        case .positional(let word):
            if onto == nil { onto = word }
        default:
            return nil
        }
    }
    if pendingOnto { return nil }
    return .rebase(verb: verb, onto: onto)
}

private let rebaseSkipLongs: Set<String> = [
    "quiet", "autostash", "no-autostash",
    "keep-empty", "rebase-merges", "no-keep-empty",
    "apply", "merge",
]

// MARK: - `[String]` adapters
//
// `AnalyzeGit` and the existing goldens still thread `[String]`; T4 moves
// the call sites onto `Argv` and deletes these.

@available(*, deprecated, message: "Use the Argv overload; T4 deletes this adapter")
func parsePush(_ args: [String], context: GitAnalysisContext) -> GitAction? {
    parsePush(Argv(program: "git", args: args), context: context)
}

@available(*, deprecated, message: "Use the Argv overload; T4 deletes this adapter")
func parseBranch(_ args: [String]) -> GitAction? {
    parseBranch(Argv(program: "git", args: args))
}

@available(*, deprecated, message: "Use the Argv overload; T4 deletes this adapter")
func parseTag(_ args: [String]) -> GitAction? {
    parseTag(Argv(program: "git", args: args))
}

@available(*, deprecated, message: "Use the Argv overload; T4 deletes this adapter")
func parseStash(_ args: [String]) -> GitAction? {
    parseStash(Argv(program: "git", args: args))
}

@available(*, deprecated, message: "Use the Argv overload; T4 deletes this adapter")
func parseRebase(_ args: [String]) -> GitAction? {
    parseRebase(Argv(program: "git", args: args))
}

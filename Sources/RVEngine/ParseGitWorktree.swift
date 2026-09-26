import RVDomain

// MARK: - Total Argv parsers (C1 T3b2)
//
// Each parser classifies `Argv` words with `FlagToken` plus pending/separator
// state instead of `ShellPipeline.scanFlags`: legacy consumes post-`--`
// words and pending values verbatim, and rejects attached `--branch=` /
// `--orphan=x` / `--source=` / `--create=x` / `--exclude=x` while accepting
// the same values bare — distinctions the value-merging scan cannot express.
// Parsed `GitAction` output is unchanged, including the dead skip entries
// (`-m` in restore) that legacy rejects via its cluster-first ordering.

func parseCheckout(_ argv: Argv) -> GitAction? {
    var create = false
    var forceCreate = false
    var orphan = false
    var force = false
    var pendingName = false
    var before: [String] = []
    var after: [String] = []
    var seenDash = false
    for word in argv.args {
        if pendingName {
            if word.hasPrefix("-") { return nil }
            before.append(word)
            pendingName = false
            continue
        }
        if seenDash {
            after.append(word)
            continue
        }
        switch FlagToken.classify(word) {
        case .terminator:
            seenDash = true
        case .long("branch", let attached):
            if let attached {
                guard attached.isEmpty == false else { return nil }
                create = true
                before.append(attached)
            } else {
                create = true
                pendingName = true
            }
        case .long("orphan", nil):
            orphan = true
            pendingName = true
        case .shorts(let letters, _):
            for letter in letters {
                switch letter {
                case "q", "l", "t", "m":
                    break
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
        case .long("force", nil):
            force = true
        case .long("conflict", let attached) where attached != nil:
            break
        case .long(let flag, nil) where checkoutSkipLongs.contains(flag):
            break
        case .positional(let word):
            before.append(word)
        default:
            return nil
        }
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

private let checkoutSkipLongs: Set<String> = [
    "quiet", "track", "no-track",
    "detach", "progress", "no-progress",
    "ignore-other-worktrees", "guess", "no-guess",
    "recurse-submodules", "no-recurse-submodules",
    "overlay", "no-overlay", "overwrite-ignore", "no-overwrite-ignore",
    "ignore-skip-worktree-bits", "merge",
    "ours", "theirs",
]

func parseSwitch(_ argv: Argv) -> GitAction? {
    var create = false
    var forceCreate = false
    var force = false
    var pendingName = false
    var name: String?
    for word in argv.args {
        if pendingName {
            if word.hasPrefix("-") { return nil }
            name = word
            pendingName = false
            continue
        }
        switch FlagToken.classify(word) {
        case .long("create", nil):
            create = true
            pendingName = true
        case .long("force-create", nil):
            forceCreate = true
            pendingName = true
        case .shorts(let letters, _):
            for letter in letters {
                switch letter {
                case "q", "d", "m", "t":
                    break
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
        case .long("force", nil), .long("discard-changes", nil):
            force = true
        case .long(let flag, nil) where switchSkipLongs.contains(flag):
            break
        case .positional(let word):
            if name != nil { return nil }
            name = word
        default:
            return nil
        }
    }
    if pendingName { return nil }
    guard let name else { return nil }
    if create || forceCreate {
        return .createBranch(name: name, startPoint: nil, force: forceCreate)
    }
    return .switchBranch(name: name, force: force)
}

private let switchSkipLongs: Set<String> = [
    "quiet", "detach", "guess", "no-guess",
    "track", "no-track", "merge",
    "ignore-other-worktrees", "recurse-submodules", "no-recurse-submodules",
]

func parseRestore(_ argv: Argv) -> GitAction? {
    var staged = false
    var worktree = false
    var source: String?
    var pathspecs: [String] = []
    var seenDash = false
    var pendingSource = false
    for word in argv.args {
        if pendingSource {
            source = word
            pendingSource = false
            continue
        }
        if seenDash {
            pathspecs.append(word)
            continue
        }
        switch FlagToken.classify(word) {
        case .terminator:
            seenDash = true
        case .long("staged", nil):
            staged = true
        case .long("worktree", nil):
            worktree = true
        case .long("source", let attached):
            if let attached {
                guard attached.isEmpty == false else { return nil }
                source = attached
            } else {
                pendingSource = true
            }
        case .shorts(let letters, _):
            for letter in letters {
                switch letter {
                case "S":
                    staged = true
                case "W":
                    worktree = true
                case "q":
                    break
                default:
                    return nil
                }
            }
        case .long(let flag, nil) where restoreSkipLongs.contains(flag):
            break
        case .positional(let word):
            pathspecs.append(word)
        default:
            return nil
        }
    }
    if pendingSource { return nil }
    let destination: GitRestoreDestination
    switch (staged, worktree) {
    case (true, true):
        destination = .worktreeAndIndex
    case (true, false):
        destination = .index
    case (false, true), (false, false):
        destination = .worktree
    }
    return .restore(pathspecs: pathspecs, destination: destination, source: source)
}

private let restoreSkipLongs: Set<String> = [
    "quiet", "progress", "no-progress", "ours", "theirs",
    "merge", "ignore-unmerged", "ignore-skip-worktree-bits",
    "overlay", "no-overlay",
]

func parseReset(_ argv: Argv) -> GitAction? {
    var mode: GitResetMode = .mixed
    var sawMode = false
    var target: String?
    var seenDash = false
    var pathspecs: [String] = []
    for word in argv.args {
        if seenDash {
            pathspecs.append(word)
            continue
        }
        switch FlagToken.classify(word) {
        case .terminator:
            seenDash = true
        case .long("hard", nil):
            if sawMode { return nil }
            mode = .hard
            sawMode = true
        case .long("soft", nil):
            if sawMode { return nil }
            mode = .soft
            sawMode = true
        case .long("mixed", nil):
            if sawMode { return nil }
            mode = .mixed
            sawMode = true
        case .long("merge", nil):
            if sawMode { return nil }
            mode = .merge
            sawMode = true
        case .long("keep", nil):
            if sawMode { return nil }
            mode = .keep
            sawMode = true
        case .shorts(let letters, _):
            guard letters.count == 1, let letter = letters.first,
                letter == "q" || letter == "N"
            else {
                return nil
            }
        case .long("quiet", nil), .long("intent-to-add", nil):
            break
        case .positional(let word):
            if target != nil { return nil }
            target = word
        default:
            return nil
        }
    }
    if pathspecs.isEmpty == false {
        if mode == .hard {
            return .discardWorktree(pathspecs: pathspecs, source: target)
        }
        return nil
    }
    return .reset(mode: mode, target: target)
}

func parseClean(_ argv: Argv) -> GitAction? {
    var force = false
    var dryRun = false
    var directories = false
    var pendingExclude = false
    for word in argv.args {
        if pendingExclude {
            pendingExclude = false
            continue
        }
        switch FlagToken.classify(word) {
        case .terminator:
            break
        case .long("force", nil):
            force = true
        case .long("dry-run", nil):
            dryRun = true
        case .long("exclude", nil):
            pendingExclude = true
        case .shorts(let letters, _):
            if letters == ["e"] {
                pendingExclude = true
            } else {
                for letter in letters {
                    switch letter {
                    case "f":
                        force = true
                    case "n":
                        dryRun = true
                    case "d":
                        directories = true
                    case "q", "x", "X":
                        break
                    case "i", "e":
                        return nil
                    default:
                        return nil
                    }
                }
            }
        case .long("quiet", nil):
            break
        case .positional:
            break
        default:
            return nil
        }
    }
    if pendingExclude { return nil }
    return .clean(force: force, dryRun: dryRun, directories: directories)
}

// MARK: - `[String]` adapters
//
// `AnalyzeGit` and the existing goldens still thread `[String]`; T4 moves
// the call sites onto `Argv` and deletes these.

func parseCheckout(_ args: [String]) -> GitAction? {
    parseCheckout(Argv(program: "git", args: args))
}

func parseSwitch(_ args: [String]) -> GitAction? {
    parseSwitch(Argv(program: "git", args: args))
}

func parseRestore(_ args: [String]) -> GitAction? {
    parseRestore(Argv(program: "git", args: args))
}

func parseReset(_ args: [String]) -> GitAction? {
    parseReset(Argv(program: "git", args: args))
}

func parseClean(_ args: [String]) -> GitAction? {
    parseClean(Argv(program: "git", args: args))
}

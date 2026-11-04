/// Git accepts unambiguous abbreviations of long options (`git reset --har`
/// reads `--hard`). The verb parsers match exact long names, so an
/// abbreviation would parse as unknown and fall open. This rewrites a unique
/// prefix to its full name before parsing. Ambiguous or unknown spellings are
/// left untouched: git itself rejects an ambiguous prefix, so nothing runs.
func resolveGitLongOptions(subcommand: String, args: [String]) -> [String] {
    guard let known = gitKnownLongs[subcommand] else { return args }
    var terminated = false
    return args.map { word in
        if terminated { return word }
        if word == "--" {
            terminated = true
            return word
        }
        guard word.hasPrefix("--"), word.count > 2 else { return word }
        let body = word.dropFirst(2)
        let name = body.prefix { $0 != "=" }
        let suffix = body.dropFirst(name.count)
        if known.contains(String(name)) { return word }
        let candidates = known.filter { $0.hasPrefix(name) }
        guard candidates.count == 1, let full = candidates.first else { return word }
        return "--" + full + suffix
    }
}

private let gitKnownLongs: [String: Set<String>] = [
    "reset": [
        "hard", "soft", "mixed", "merge", "keep", "quiet", "no-quiet", "patch",
        "intent-to-add", "recurse-submodules", "no-recurse-submodules",
        "pathspec-from-file", "pathspec-file-nul", "no-pathspec-file-nul",
        "no-refresh", "refresh",
    ],
    "checkout": [
        "branch", "orphan", "force", "conflict", "quiet", "progress", "no-progress",
        "ours", "theirs", "merge", "detach", "track", "no-track", "patch",
        "ignore-other-worktrees", "overwrite-ignore", "no-overwrite-ignore",
        "recurse-submodules", "no-recurse-submodules", "guess", "no-guess",
        "pathspec-from-file", "pathspec-file-nul", "ignore-skip-worktree-bits",
        "overlay", "no-overlay", "ignore-unmerged",
    ],
    "clean": ["force", "dry-run", "exclude", "quiet", "interactive"],
    "restore": [
        "staged", "worktree", "source", "quiet", "progress", "no-progress", "ours",
        "theirs", "merge", "ignore-unmerged", "ignore-skip-worktree-bits", "overlay",
        "no-overlay", "patch", "pathspec-from-file", "pathspec-file-nul",
        "recurse-submodules", "no-recurse-submodules", "conflict",
    ],
    "switch": [
        "create", "force-create", "discard-changes", "force", "detach", "guess",
        "no-guess", "track", "no-track", "orphan", "merge", "conflict", "quiet",
        "progress", "no-progress", "recurse-submodules", "no-recurse-submodules",
        "ignore-other-worktrees",
    ],
    "branch": [
        "delete", "force", "move", "copy", "list", "create-reflog", "show-current",
        "verbose", "quiet", "track", "no-track", "set-upstream-to", "unset-upstream",
        "edit-description", "merged", "no-merged", "contains", "no-contains", "all",
        "remotes", "sort", "points-at", "ignore-case", "format", "omit-empty",
    ],
]

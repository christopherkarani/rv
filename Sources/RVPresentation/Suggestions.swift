import RVDomain

public enum SuggestionKind: Equatable, Sendable {
    case previewFirst
    case saferAlternative
    case workflowFix
    case documentation

    public var title: String {
        switch self {
        case .previewFirst:
            return "Preview first"
        case .saferAlternative:
            return "Safer alternative"
        case .workflowFix:
            return "Workflow fix"
        case .documentation:
            return "Documentation"
        }
    }
}

public struct ExplainSuggestion: Equatable, Sendable {
    public var kind: SuggestionKind
    public var text: String
    public var command: String?
    public var url: String?

    public init(kind: SuggestionKind, text: String, command: String? = nil, url: String? = nil) {
        self.kind = kind
        self.text = text
        self.command = command
        self.url = url
    }
}

public func suggestions(for ruleID: RuleID) -> [ExplainSuggestion] {
    dayOneSuggestions[ruleID] ?? []
}

private func preview(_ text: String, command: String? = nil, url: String? = nil) -> ExplainSuggestion {
    ExplainSuggestion(kind: .previewFirst, text: text, command: command, url: url)
}

private func safer(_ text: String, command: String? = nil, url: String? = nil) -> ExplainSuggestion {
    ExplainSuggestion(kind: .saferAlternative, text: text, command: command, url: url)
}

private func workflow(_ text: String, command: String? = nil, url: String? = nil) -> ExplainSuggestion {
    ExplainSuggestion(kind: .workflowFix, text: text, command: command, url: url)
}

private func docs(_ text: String, url: String? = nil) -> ExplainSuggestion {
    ExplainSuggestion(kind: .documentation, text: text, url: url)
}

private let rmRfSuggestions: [ExplainSuggestion] = [
    preview("List contents first with `ls -la` to verify target"),
    safer("Use `rm -ri` for interactive confirmation of each file", command: "rm -ri path/"),
    workflow("Move to trash instead: `mv path ~/.Trash/`"),
]

private let findDeleteSuggestions: [ExplainSuggestion] = [
    preview("Run the same `find` without `-delete` (or with `-ls`) to see matches"),
    safer("Delete selected paths interactively after reviewing the listing"),
    workflow("Move matches to `~/.Trash/` instead of deleting in place"),
]

private let unlinkSuggestions: [ExplainSuggestion] = [
    preview("Inspect the file with `ls -l` before removing it"),
    safer("Move the file to `~/.Trash/` instead of unlinking it"),
]

private let truncateSuggestions: [ExplainSuggestion] = [
    preview("Confirm the file with `ls -l` before shrinking or zeroing it"),
    safer("Copy the file first, then truncate the copy if you still need a blank file"),
]

private let shredSuggestions: [ExplainSuggestion] = [
    preview("Confirm the file with `ls -l` before overwriting it"),
    safer("Move the file to `~/.Trash/` if you only need it gone"),
]

private let ddOverwriteSuggestions: [ExplainSuggestion] = [
    preview("Confirm `of=` with `ls -l` before writing"),
    safer("Do not use `dd` to wipe a file; copy or replace it explicitly"),
]

private let tarRemoveSuggestions: [ExplainSuggestion] = [
    preview("List the archive first with `tar -tvf` and omit `--remove-files`"),
    safer("Create the archive without deleting the sources"),
]

private let mvSensitiveSuggestions: [ExplainSuggestion] = [
    preview("List the source with `ls -la` before moving it"),
    safer("Rename in place or move to `~/.Trash/` instead of a destructive destination"),
]

private let copyThenDeleteSuggestions: [ExplainSuggestion] = [
    preview("Keep the source; copy, link, or sync without a follow-up delete"),
    safer("If the source must leave the tree, move it to `~/.Trash/`"),
]

private let redirectTruncateSuggestions: [ExplainSuggestion] = [
    preview("Confirm the file with `ls -l` before redirecting over it"),
    safer("Write to a new file, then replace the original if the write succeeds"),
]

private let checkoutDiscardSuggestions: [ExplainSuggestion] = [
    preview(
        "Run `git status` and `git diff` to see uncommitted changes that would be lost",
        command: "git status && git diff"
    ),
    workflow("Commit or stash changes before discarding", command: "git stash"),
]

private let restoreWorktreeSuggestions: [ExplainSuggestion] = [
    preview("Run `git diff` to see uncommitted changes that would be lost", command: "git diff"),
    safer(
        "Use `git stash` to save changes (retrievable later) instead of discarding",
        command: "git stash"
    ),
    workflow(
        "Commit changes before discarding to preserve them in history",
        command: "git commit -m 'WIP: saving changes'"
    ),
]

private let forcePushSuggestions: [ExplainSuggestion] = [
    safer(
        "Use `git push --force-with-lease` to prevent overwriting others' work",
        command: "git push --force-with-lease"
    ),
    preview("Run `git log origin/branch..HEAD` to see commits being pushed"),
    workflow("Coordinate with team before force pushing to shared branches"),
]

private let dayOneSuggestions: [RuleID: [ExplainSuggestion]] = {
    var catalog: [RuleID: [ExplainSuggestion]] = [
        RuleID(pack: .coreGit, pattern: "reset-hard"): [
            preview(
                "Run `git diff` and `git status` to see what would be lost",
                command: "git diff && git status"
            ),
            safer(
                "Use `git reset --soft` or `--mixed` to preserve changes",
                command: "git reset --soft"
            ),
            workflow(
                "Consider using `git stash` to save changes temporarily",
                command: "git stash"
            ),
            docs("See Git documentation for reset options", url: "https://git-scm.com/docs/git-reset"),
        ],
        RuleID(pack: .coreGit, pattern: "clean-force"): [
            preview("Run `git clean -n` to preview what would be deleted", command: "git clean -n -fd"),
            safer("Use `git clean -i` for interactive mode to select files", command: "git clean -i"),
            workflow("Add patterns to .gitignore instead of cleaning"),
        ],
        RuleID(pack: .coreGit, pattern: "push-force-long"): forcePushSuggestions,
        RuleID(pack: .coreGit, pattern: "push-force-short"): forcePushSuggestions,
        RuleID(pack: .coreGit, pattern: "checkout-discard"): checkoutDiscardSuggestions,
        RuleID(pack: .coreGit, pattern: "checkout-ref-discard"): checkoutDiscardSuggestions,
        RuleID(pack: .coreGit, pattern: "branch-force-delete"): [
            preview("Check if branch has unmerged commits with `git log branch --not main`"),
            safer(
                "Use `git branch -d` (lowercase) to only delete if merged",
                command: "git branch -d branch-name"
            ),
        ],
        RuleID(pack: .coreGit, pattern: "restore-worktree"): restoreWorktreeSuggestions,
        RuleID(pack: .coreGit, pattern: "restore-worktree-explicit"): restoreWorktreeSuggestions,
        RuleID(pack: .coreGit, pattern: "reset-merge"): [
            preview(
                "Run `git status` to see uncommitted changes that could be lost",
                command: "git status"
            ),
            safer(
                "Use `git merge --abort` to cleanly abort an in-progress merge",
                command: "git merge --abort"
            ),
        ],
        RuleID(pack: .coreGit, pattern: "stash-drop"): [
            preview(
                "List stashes with `git stash list` and view contents with `git stash show -p`",
                command: "git stash list"
            ),
            safer(
                "Apply the stash first with `git stash apply` before dropping",
                command: "git stash apply"
            ),
        ],
        RuleID(pack: .coreGit, pattern: "stash-clear"): [
            preview(
                "List all stashes with `git stash list` to review what would be deleted",
                command: "git stash list"
            ),
            workflow(
                "Drop stashes individually with `git stash drop` for more control",
                command: "git stash drop stash@{0}"
            ),
        ],
    ]

    for ruleID in [
        RuleID(pack: .coreFilesystem, pattern: "rm-rf-root-home"),
        RuleID(pack: .coreFilesystem, pattern: "rm-r-f-separate-root-home"),
        RuleID(pack: .coreFilesystem, pattern: "rm-recursive-force-root-home"),
        RuleID(pack: .coreFilesystem, pattern: "rm-rf-general"),
        RuleID(pack: .coreFilesystem, pattern: "rm-r-f-separate"),
        RuleID(pack: .coreFilesystem, pattern: "rm-recursive-force-long"),
    ] {
        catalog[ruleID] = rmRfSuggestions
    }
    for ruleID in [
        RuleID(pack: .coreFilesystem, pattern: "find-delete-root-home"),
        RuleID(pack: .coreFilesystem, pattern: "find-delete-general"),
    ] {
        catalog[ruleID] = findDeleteSuggestions
    }
    for ruleID in [
        RuleID(pack: .coreFilesystem, pattern: "unlink-root-home"),
        RuleID(pack: .coreFilesystem, pattern: "unlink-general"),
    ] {
        catalog[ruleID] = unlinkSuggestions
    }
    for ruleID in [
        RuleID(pack: .coreFilesystem, pattern: "truncate-zero-root-home"),
        RuleID(pack: .coreFilesystem, pattern: "truncate-zero-general"),
    ] {
        catalog[ruleID] = truncateSuggestions
    }
    for ruleID in [
        RuleID(pack: .coreFilesystem, pattern: "shred-root-home"),
        RuleID(pack: .coreFilesystem, pattern: "shred-general"),
    ] {
        catalog[ruleID] = shredSuggestions
    }
    for ruleID in [
        RuleID(pack: .coreFilesystem, pattern: "tar-remove-files-root-home"),
        RuleID(pack: .coreFilesystem, pattern: "tar-remove-files-general"),
    ] {
        catalog[ruleID] = tarRemoveSuggestions
    }
    for ruleID in [
        RuleID(pack: .coreFilesystem, pattern: "dd-overwrite-root-home"),
        RuleID(pack: .coreFilesystem, pattern: "dd-overwrite-general"),
    ] {
        catalog[ruleID] = ddOverwriteSuggestions
    }
    catalog[RuleID(pack: .coreFilesystem, pattern: "mv-sensitive-source-root-home")] = mvSensitiveSuggestions
    for ruleID in [
        RuleID(pack: .coreFilesystem, pattern: "cp-sensitive-then-delete"),
        RuleID(pack: .coreFilesystem, pattern: "ln-symlink-sensitive-then-delete"),
        RuleID(pack: .coreFilesystem, pattern: "rsync-sensitive-then-delete"),
    ] {
        catalog[ruleID] = copyThenDeleteSuggestions
    }
    catalog[RuleID(pack: .coreFilesystem, pattern: "redirect-truncate-root-home")] = redirectTruncateSuggestions
    return catalog
}()

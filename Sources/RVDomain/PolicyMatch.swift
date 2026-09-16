/// Pure matcher from closed `PolicyPredicate` to a typed Git or filesystem action.
/// `supportingCommand` is evidence only and is never read.
public enum PolicyMatch: Sendable {
    public static func matches(_ predicate: PolicyPredicate, action: GitAction) -> Bool {
        switch predicate {
        case .gitPush(let force, let branch):
            return matchesGitPush(
                wantForce: force,
                wantBranch: branch,
                on: action
            )
        case .gitDiscardWorktree(let pathspec):
            return matchesDiscardWorktree(wantPathspec: pathspec, on: action)
        case .gitReset(let mode):
            return matchesReset(wantMode: mode, on: action)
        case .gitClean(let force, let directories):
            return matchesClean(wantForce: force, wantDirectories: directories, on: action)
        case .filesystemDelete, .filesystemMove:
            return false
        }
    }

    public static func matches(_ predicate: PolicyPredicate, action: FilesystemAction) -> Bool {
        switch predicate {
        case .filesystemDelete(let recursive, let force):
            return matchesDelete(wantRecursive: recursive, wantForce: force, on: action)
        case .filesystemMove:
            if case .move = action {
                return true
            }
            return false
        case .gitPush, .gitDiscardWorktree, .gitReset, .gitClean:
            return false
        }
    }

    private static func matchesGitPush(
        wantForce: GitPushForceConstraint,
        wantBranch: String?,
        on action: GitAction
    ) -> Bool {
        guard case .push(_, let refspec, let force) = action else {
            return false
        }
        if case .exactly(let want) = wantForce, want != force {
            return false
        }
        if let wantBranch, names(wantBranch, refspec: refspec ?? action.resources.branchName) == false {
            return false
        }
        return true
    }

    private static func matchesDiscardWorktree(wantPathspec: String?, on action: GitAction) -> Bool {
        let pathspecs: [String]
        switch action {
        case .discardWorktree(let specs, _):
            pathspecs = specs
        case .restore(let specs, let destination, _):
            switch destination {
            case .worktree, .worktreeAndIndex:
                pathspecs = specs
            case .index:
                return false
            }
        default:
            return false
        }
        guard let wantPathspec else {
            return true
        }
        return pathspecs.contains(wantPathspec)
    }

    private static func matchesReset(wantMode: GitResetMode?, on action: GitAction) -> Bool {
        guard case .reset(let mode, _) = action else {
            return false
        }
        if let wantMode, wantMode != mode {
            return false
        }
        return true
    }

    private static func matchesClean(
        wantForce: Bool?,
        wantDirectories: Bool?,
        on action: GitAction
    ) -> Bool {
        guard case .clean(let force, _, let directories) = action else {
            return false
        }
        if let wantForce, wantForce != force {
            return false
        }
        if let wantDirectories, wantDirectories != directories {
            return false
        }
        return true
    }

    private static func matchesDelete(
        wantRecursive: Bool?,
        wantForce: Bool?,
        on action: FilesystemAction
    ) -> Bool {
        guard case .delete(_, let recursive, let force) = action else {
            return false
        }
        if let wantRecursive, wantRecursive != recursive {
            return false
        }
        if let wantForce, wantForce != force {
            return false
        }
        return true
    }

    /// Destination of a Git push refspec: `main`, `HEAD:main`, `refs/heads/main`, `+main`.
    private static func names(_ wanted: String, refspec: String?) -> Bool {
        guard let raw = refspec, raw.isEmpty == false else {
            return false
        }
        var spec = raw[...]
        if spec.first == "+" {
            spec = spec.dropFirst()
        }
        let destination: Substring
        if let colon = spec.lastIndex(of: ":") {
            destination = spec[spec.index(after: colon)...]
        } else {
            destination = spec
        }
        if destination == wanted[...] {
            return true
        }
        return destination.hasSuffix("/" + wanted)
    }
}

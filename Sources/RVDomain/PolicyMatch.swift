/// Pure matcher from closed `PolicyPredicate` to a typed action.
/// `supportingCommand` is evidence only and is never read.
public enum PolicyMatch: Sendable {
    public static func matches(_ predicate: PolicyPredicate, action: ProposedAction) -> Bool {
        switch predicate {
        case .gitPush(let force, let branch):
            return matchesGitPush(
                wantForce: force,
                wantBranch: branch,
                on: action
            )
        }
    }

    public static func matches(_ predicate: PolicyPredicate, action: GitAction) -> Bool {
        switch predicate {
        case .gitPush(let force, let branch):
            return matchesGitPush(
                wantForce: force,
                wantBranch: branch,
                on: action
            )
        }
    }

    private static func matchesGitPush(
        wantForce: GitPushForce?,
        wantBranch: String?,
        on action: GitAction
    ) -> Bool {
        guard case .push(_, let refspec, let force, let delete) = action, delete == false else {
            return false
        }
        if let wantForce, wantForce != force {
            return false
        }
        if let wantBranch, names(wantBranch, refspec: refspec ?? action.resources.branchName) == false {
            return false
        }
        return true
    }

    private static func matchesGitPush(
        wantForce: GitPushForce?,
        wantBranch: String?,
        on action: ProposedAction
    ) -> Bool {
        guard looksLikeGitPush(action) else {
            return false
        }
        if let wantForce, proposedForceMatches(wantForce, effects: action.effects) == false {
            return false
        }
        if let wantBranch, names(wantBranch, refspec: action.resources.branchName) == false {
            return false
        }
        return true
    }

    /// `ProposedAction` has no `GitPushForce`; `.force` and `.forceWithLease` both mean remote mutation.
    private static func proposedForceMatches(_ want: GitPushForce, effects: ActionEffects) -> Bool {
        let mutated = effects.kinds.contains(.remoteSharedBranchMutation)
        switch want {
        case .none:
            return mutated == false
        case .force, .forceWithLease:
            return mutated
        }
    }

    private static func looksLikeGitPush(_ action: ProposedAction) -> Bool {
        let kinds = action.effects.kinds
        if kinds.contains(where: isNonPushEffect) {
            return false
        }
        if kinds.contains(.remoteSharedBranchMutation) {
            return true
        }
        return kinds.isEmpty
            && (action.resources.branchName != nil || action.resources.remoteName != nil)
    }

    private static func isNonPushEffect(_ kind: ActionEffectKind) -> Bool {
        switch kind {
        case .remoteSharedBranchMutation:
            return false
        case .localBranchCreate, .workingTreeDiscard, .filesystemDelete, .filesystemMove,
            .filesystemOverwrite, .filesystemModeChange, .filesystemCreate, .filesystemRead,
            .protectedPathMutation, .outsideRepositoryMutation, .unresolvedFilesystem:
            return true
        }
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

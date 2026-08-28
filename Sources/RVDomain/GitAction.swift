/// Local working-tree / index versus shared remote effect.
public enum GitEffectScope: String, Sendable, Equatable, Codable {
    case localWorkingTree
    case localIndex
    case localWorkingTreeAndIndex
    case localRef
    case remote
}

public enum GitPushForce: String, Sendable, Equatable, Codable {
    case none
    case forceWithLease
    case force
}

public enum GitResetMode: String, Sendable, Equatable, Codable {
    case soft
    case mixed
    case hard
    case merge
    case keep
}

public enum GitStashVerb: String, Sendable, Equatable, Codable {
    case push
    case pop
    case apply
    case drop
    case clear
    case list
    case show
}

public enum GitRebaseVerb: String, Sendable, Equatable, Codable {
    case start
    case abort
    case continueRebase = "continue"
    case skip
}

/// Typed Git operation. Flags, refs, remotes, and pathspecs live on the case.
public enum GitAction: Sendable, Equatable, Codable {
    case createBranch(name: String, startPoint: String?, force: Bool)
    case switchBranch(name: String, force: Bool)
    case discardWorktree(pathspecs: [String], source: String?)
    case restore(pathspecs: [String], staged: Bool, worktree: Bool, source: String?)
    case reset(mode: GitResetMode, target: String?)
    case clean(force: Bool, dryRun: Bool, directories: Bool)
    case push(remote: String?, refspec: String?, force: GitPushForce, delete: Bool)
    case deleteBranch(name: String, force: Bool, remote: Bool)
    case deleteTag(name: String, remote: String?)
    case stash(verb: GitStashVerb)
    case rebase(verb: GitRebaseVerb, onto: String?)

    public var effectScope: GitEffectScope {
        switch self {
        case .createBranch, .switchBranch, .deleteBranch(_, _, false):
            return .localRef
        case .discardWorktree, .clean:
            return .localWorkingTree
        case .restore(_, let staged, let worktree, _):
            if worktree { return .localWorkingTree }
            if staged { return .localIndex }
            return .localWorkingTree
        case .reset(let mode, _):
            switch mode {
            case .hard, .merge:
                return .localWorkingTreeAndIndex
            case .keep, .mixed, .soft:
                return .localIndex
            }
        case .push, .deleteBranch(_, _, true), .deleteTag:
            return .remote
        case .stash, .rebase:
            return .localRef
        }
    }

    public var effects: ActionEffects {
        ActionEffects(kinds: effectKinds)
    }

    public var resources: ActionResources {
        switch self {
        case .createBranch(let name, _, _), .switchBranch(let name, _):
            return ActionResources(branchName: name)
        case .push(let remote, let refspec, _, _):
            return ActionResources(remoteName: remote, branchName: refspec)
        case .deleteBranch(let name, _, _):
            return ActionResources(branchName: name)
        case .deleteTag(let name, let remote):
            return ActionResources(remoteName: remote, branchName: name)
        case .discardWorktree, .restore, .reset, .clean, .stash, .rebase:
            return ActionResources()
        }
    }

    public var explainAction: String {
        switch self {
        case .createBranch(_, _, false):
            return "branch creation"
        case .createBranch(_, _, true):
            return "force branch create/reset"
        case .switchBranch:
            return "branch switch"
        case .discardWorktree:
            return "working-tree overwrite/discard"
        case .restore(_, _, true, _):
            return "working-tree overwrite/discard"
        case .restore(_, true, false, _):
            return "index unstage"
        case .restore:
            return "restore"
        case .reset(let mode, _):
            switch mode {
            case .hard: return "reset --hard"
            case .merge: return "reset --merge"
            case .keep: return "reset --keep"
            case .soft: return "reset --soft"
            case .mixed: return "reset --mixed"
            }
        case .clean(_, true, _):
            return "clean dry-run"
        case .clean(true, false, _):
            return "clean force"
        case .clean:
            return "clean"
        case .push(_, _, .force, false):
            return "force-push"
        case .push(_, _, .forceWithLease, false):
            return "force-push with lease"
        case .push(_, _, .none, true):
            return "remote ref delete"
        case .push(_, _, _, true):
            return "force remote ref delete"
        case .push:
            return "push"
        case .deleteBranch(_, _, true):
            return "remote branch delete"
        case .deleteBranch(_, true, false):
            return "force branch delete"
        case .deleteBranch:
            return "branch delete"
        case .deleteTag:
            return "tag delete"
        case .stash(let verb):
            return "stash \(verb.rawValue)"
        case .rebase(.abort, _):
            return "rebase abort"
        case .rebase(.continueRebase, _):
            return "rebase continue"
        case .rebase(.skip, _):
            return "rebase skip"
        case .rebase:
            return "rebase"
        }
    }

    public var explainScope: String {
        switch effectScope {
        case .localWorkingTree:
            return "local working tree"
        case .localIndex:
            return "local index"
        case .localWorkingTreeAndIndex:
            return "local working tree and index"
        case .localRef:
            return "local"
        case .remote:
            return "remote"
        }
    }

    public var explainEffect: String? {
        if effectKinds.contains(.workingTreeDiscard) {
            return "working-tree discard"
        }
        if effectKinds.contains(.remoteSharedBranchMutation) {
            return "remote shared-branch mutation"
        }
        if effectKinds.contains(.localBranchCreate) {
            return "local branch create"
        }
        return nil
    }

    public var explainRemote: String? {
        resources.remoteName
    }

    public var explainRef: String? {
        switch self {
        case .createBranch(let name, _, _), .switchBranch(let name, _),
            .deleteBranch(let name, _, _), .deleteTag(let name, _):
            return name
        case .push(_, let refspec, _, _):
            return refspec
        case .reset(_, let target):
            return target
        case .rebase(_, let onto):
            return onto
        case .discardWorktree, .restore, .clean, .stash:
            return nil
        }
    }

    public var explainPathspec: String? {
        switch self {
        case .discardWorktree(let pathspecs, _), .restore(let pathspecs, _, _, _):
            return pathspecs.isEmpty ? nil : pathspecs.joined(separator: " ")
        default:
            return nil
        }
    }

    public func proposedAction(
        command: ShellCommand,
        workingDirectory: WorkingDirectory?
    ) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: fingerprint),
                effects: effects,
                resources: resources,
                scope: ActionScope(workingDirectory: workingDirectory),
                supportingCommand: command
            )
        )
    }

    private var effectKinds: [ActionEffectKind] {
        switch self {
        case .createBranch(_, _, false):
            return [.localBranchCreate]
        case .discardWorktree:
            return [.workingTreeDiscard]
        case .restore(_, _, let worktree, _):
            return worktree ? [.workingTreeDiscard] : []
        case .reset(let mode, _):
            switch mode {
            case .hard, .merge:
                return [.workingTreeDiscard]
            case .soft, .mixed, .keep:
                return []
            }
        case .clean(let force, let dryRun, _):
            return force && dryRun == false ? [.workingTreeDiscard] : []
        case .push(_, _, let force, let delete):
            return force != .none || delete ? [.remoteSharedBranchMutation] : []
        case .switchBranch(_, true):
            return [.workingTreeDiscard]
        case .createBranch, .switchBranch, .deleteBranch, .deleteTag, .stash, .rebase:
            return []
        }
    }

    private var fingerprint: String {
        switch self {
        case .createBranch(let name, _, let force):
            return "shell:git.create-branch:\(force ? "force:" : "")\(name)"
        case .switchBranch(let name, let force):
            return "shell:git.switch:\(force ? "force:" : "")\(name)"
        case .discardWorktree(let pathspecs, let source):
            return "shell:git.discard:\(source ?? ""):\(pathspecs.joined(separator: ","))"
        case .restore(let pathspecs, let staged, let worktree, _):
            return "shell:git.restore:\(staged):\(worktree):\(pathspecs.joined(separator: ","))"
        case .reset(let mode, let target):
            return "shell:git.reset:\(mode.rawValue):\(target ?? "")"
        case .clean(let force, let dryRun, let directories):
            return "shell:git.clean:\(force):\(dryRun):\(directories)"
        case .push(let remote, let refspec, let force, let delete):
            return "shell:git.push:\(force.rawValue):\(delete):\(remote ?? ""):\(refspec ?? "")"
        case .deleteBranch(let name, let force, let remote):
            return "shell:git.delete-branch:\(force):\(remote):\(name)"
        case .deleteTag(let name, let remote):
            return "shell:git.delete-tag:\(remote ?? ""):\(name)"
        case .stash(let verb):
            return "shell:git.stash:\(verb.rawValue)"
        case .rebase(let verb, let onto):
            return "shell:git.rebase:\(verb.rawValue):\(onto ?? "")"
        }
    }
}

import Foundation
import RVDomain

public enum PinnedRulePolarity: String, Sendable, Equatable {
    case allow
    case block
}

public enum RuleHardStopKind: Sendable, Equatable {
    case secretPath
    case protectedPath
    case protectedSharedBranch
    case workingTreeDiscard
    case outsideRepository
    case unresolvedPath
    case unwrapLimited
}

public struct RulePreview: Sendable, Equatable {
    public var sentence: String
    public var draft: String
    public var allowedToSave: Bool

    public init(sentence: String, draft: String, allowedToSave: Bool) {
        self.sentence = sentence
        self.draft = draft
        self.allowedToSave = allowedToSave
    }
}

public struct RuleSaveOutcome: Sendable, Equatable {
    public var ruleID: RuleID

    public init(ruleID: RuleID) {
        self.ruleID = ruleID
    }
}

public enum RulePinError: Error, Sendable, Equatable {
    case draftMismatch
    case hardStop
    case missingMatchingView
}

public enum RulePinning: Sendable {
    public static func preview(
        record: PendingApproval,
        polarity: PinnedRulePolarity
    ) -> RulePreview {
        let stop = hardStop(in: record.action)
        let allowedToSave = !(polarity == .allow && stop != nil)
        let predicate = gitPushPredicate(from: record.action)
        return RulePreview(
            sentence: sentence(
                polarity: polarity,
                stop: stop,
                allowedToSave: allowedToSave,
                predicate: predicate
            ),
            draft: draft(record: record, polarity: polarity),
            allowedToSave: allowedToSave
        )
    }

    public static func draft(
        record: PendingApproval,
        polarity: PinnedRulePolarity
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data?
        if let predicate = gitPushPredicate(from: record.action) {
            data = try? encoder.encode(
                TypedPinDraft(polarity: polarity.rawValue, predicate: predicate, v: 2)
            )
        } else {
            data = try? encoder.encode(
                DraftBody(
                    fingerprint: record.fingerprint.rawValue,
                    id: record.id.rawValue,
                    polarity: polarity.rawValue,
                    v: 1
                )
            )
        }
        guard let data, let text = String(data: data, encoding: .utf8) else {
            return "v1.\(polarity.rawValue).\(record.id.rawValue).\(record.fingerprint.rawValue)"
        }
        return text
    }

    public static func hardStop(in action: ProposedAction) -> RuleHardStopKind? {
        let verdict = ActionPolicyEngine.evaluate(action: action)
        if case .hardDeny(let deny) = verdict.decision {
            if deny.ruleID == ActionPolicyEngine.Builtin.workingTreeDiscard.ruleID {
                return .workingTreeDiscard
            }
            if deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID {
                return .outsideRepository
            }
            if deny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID {
                return .unresolvedPath
            }
            if deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID {
                return .protectedPath
            }
            if deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID {
                return .unwrapLimited
            }
            return .protectedSharedBranch
        }
        if secretPathOnStoredAction(action) {
            return .secretPath
        }
        return nil
    }

    public static func blocksAllowOverride(_ result: EvaluationResult) -> Bool {
        HookAuthorization.isPinned(result)
    }

    /// Exact-command pin identity. Caller supplies the T1 matching view; Policy does not peel.
    public static func ruleID(
        polarity: PinnedRulePolarity,
        matchingView: MatchingView
    ) -> RuleID {
        packedID(polarity: polarity, seed: matchingView.rawValue)
    }

    /// Typed pin identity. Honor is the predicate, not a matching view.
    public static func ruleID(
        polarity: PinnedRulePolarity,
        predicate: PolicyPredicate
    ) -> RuleID {
        packedID(polarity: polarity, seed: predicateSeed(predicate))
    }

    private static func packedID(polarity: PinnedRulePolarity, seed: String) -> RuleID {
        let packName = polarity == .allow ? "pin.allow" : "pin.block"
        return RuleID(
            pack: PackID(rawValue: packName),
            pattern: String(sha256Hex(seed).prefix(16))
        )
    }

    private static func predicateSeed(_ predicate: PolicyPredicate) -> String {
        switch predicate {
        case .gitPush(let force, let branch):
            return "gitPush|\(forceSeed(force))|\(branch ?? "")"
        case .gitDiscardWorktree(let pathspec):
            return "gitDiscardWorktree|\(pathspec ?? "")"
        case .gitReset(let mode):
            return "gitReset|\(mode?.rawValue ?? "")"
        case .gitClean(let force, let directories):
            return "gitClean|\(boolSeed(force))|\(boolSeed(directories))"
        case .filesystemDelete(let recursive, let force):
            return "filesystemDelete|\(boolSeed(recursive))|\(boolSeed(force))"
        case .filesystemMove:
            return "filesystemMove"
        }
    }

    private static func forceSeed(_ force: GitPushForceConstraint) -> String {
        switch force {
        case .any:
            return "any"
        case .exactly(let value):
            return value.rawValue
        }
    }

    private static func boolSeed(_ value: Bool?) -> String {
        guard let value else { return "" }
        return value ? "true" : "false"
    }

    private static func sentence(
        polarity: PinnedRulePolarity,
        stop: RuleHardStopKind?,
        allowedToSave: Bool,
        predicate: PolicyPredicate?
    ) -> String {
        if polarity == .allow, allowedToSave == false {
            switch stop {
            case .secretPath:
                return "This action reads a secret path. Always-allow cannot override that hard stop."
            case .protectedPath:
                return "This action mutates a protected host path. Always-allow cannot override that hard stop."
            case .workingTreeDiscard:
                return "This action discards the working tree. Always-allow cannot override that hard stop."
            case .outsideRepository:
                return "This action writes outside the repository. Always-allow cannot override that hard stop."
            case .unresolvedPath:
                return "This action has an unresolved path. Always-allow cannot override that hard stop."
            case .unwrapLimited:
                return "This action exceeded unwrap limits. Always-allow cannot override that hard stop."
            case .protectedSharedBranch, nil:
                return "This action mutates a protected shared branch. Always-allow cannot override that hard stop."
            }
        }
        if let predicate {
            return gitPushSentence(polarity: polarity, predicate: predicate)
        }
        switch polarity {
        case .allow:
            return "Always allow this action. Future matches in this scope will not wait."
        case .block:
            return "Always block this action. This wait and future matches will be denied."
        }
    }

    /// Typed form for git push pins. Matcher is `GitAction.push`, not argv.
    /// Force is taken from the analyzed push, including `.forceWithLease`.
    /// Delete-remote is not a gitPush pin.
    private static func gitPushPredicate(from action: ProposedAction) -> PolicyPredicate? {
        guard let git = gitPushAction(from: action) else {
            return nil
        }
        guard case .push(_, _, let force) = git else {
            return nil
        }
        let predicate = PolicyPredicate.gitPush(
            force: .exactly(force),
            branch: git.resources.branchName
        )
        guard PolicyMatch.matches(predicate, action: git) else {
            return nil
        }
        return predicate
    }

    private static func gitPushAction(from action: ProposedAction) -> GitAction? {
        guard case .shell(let shell) = action else {
            return nil
        }
        guard case .push(let remote, let refspec, let force)? = shell.gitAction else {
            return nil
        }
        let kinds = shell.effects.kinds
        guard kinds.contains(.remoteSharedBranchMutation) else {
            return nil
        }
        if kinds.contains(where: isNonPushEffect) {
            return nil
        }
        return .push(remote: remote, refspec: refspec, force: force)
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

    private static func gitPushSentence(
        polarity: PinnedRulePolarity,
        predicate: PolicyPredicate
    ) -> String {
        switch predicate {
        case .gitPush(let force, let branch):
            let target = gitPushTarget(force: force, branch: branch)
            switch polarity {
            case .allow:
                return "Always allow \(target). Future matches in this scope will not wait."
            case .block:
                return "Always block \(target)."
            }
        case .gitDiscardWorktree, .gitReset, .gitClean, .filesystemDelete, .filesystemMove:
            switch polarity {
            case .allow:
                return "Always allow this typed action. Future matches in this scope will not wait."
            case .block:
                return "Always block this typed action."
            }
        }
    }

    private static func gitPushTarget(force: GitPushForceConstraint, branch: String?) -> String {
        let named = branch.flatMap { $0.isEmpty ? nil : $0 }
        let isForce: Bool
        switch force {
        case .exactly(.force), .exactly(.forceWithLease):
            isForce = true
        case .any, .exactly(.none):
            isForce = false
        }
        if isForce {
            if let named {
                return "force-push to \(named)"
            }
            return "force-push"
        }
        if let named {
            return "push to \(named)"
        }
        return "git push"
    }
}

private struct DraftBody: Codable, Equatable {
    var fingerprint: String
    var id: String
    var polarity: String
    var v: Int
}

private struct TypedPinDraft: Codable, Equatable {
    var polarity: String
    var predicate: PolicyPredicate
    var v: Int
}

/// Catalog match on a path already stored on the action. Does not tokenize
/// `supportingCommand`.
private func secretPathOnStoredAction(_ action: ProposedAction) -> Bool {
    if action.resources.protectedMatch != nil {
        return true
    }
    guard let path = action.resources.path, path.isEmpty == false else {
        return false
    }
    return SecretPathCatalog.dayOne.firstMatch(of: path) != nil
}

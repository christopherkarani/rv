/// Repo/user overlay. Can only tighten a built-in zone; `.allow` is a no-op.
public enum ActionPolicyOverlay: Sendable, Equatable, Codable {
    case none
    case allow
    case deny(Deny)
    case mandatoryHuman(Deny)
}

/// Pack-engine verdict. Consumed only when no semantic rule covers the action.
public enum PackFallback: Sendable, Equatable, Codable {
    case none
    case allow
    case deny(Deny)
    case ask(Deny)

    public init(_ result: EvaluationResult) {
        switch result.decision {
        case .allow:
            self = .allow
        case .deny(let deny):
            self = .deny(deny)
        case .indeterminate:
            self = .deny(ActionPolicyEngine.Builtin.packIncomplete)
        }
    }
}

/// Effective policy fed to `ActionPolicyEngine`. No I/O; no pack files.
/// `rules` are restrict-only: typed allow cannot weaken a built-in hard deny.
public struct EffectiveActionPolicy: Sendable, Equatable, Codable {
    public var overlay: ActionPolicyOverlay
    public var packFallback: PackFallback
    public var rules: [TypedRule]

    public init(
        overlay: ActionPolicyOverlay = .none,
        packFallback: PackFallback = .none,
        rules: [TypedRule] = []
    ) {
        self.overlay = overlay
        self.packFallback = packFallback
        self.rules = rules
    }

    public static let empty = EffectiveActionPolicy()
}

/// Tiny two-run explanation. Not `rv explain` (OPE-168).
public struct ActionPolicyExplanation: Sendable, Equatable, Codable {
    public var zone: ActionPolicyZone
    public var ruleID: RuleID
    public var reason: String

    public init(zone: ActionPolicyZone, ruleID: RuleID, reason: String) {
        self.zone = zone
        self.ruleID = ruleID
        self.reason = reason
    }
}

public struct ActionPolicyVerdict: Sendable, Equatable, Codable {
    public var decision: HardPolicyDecision
    public var explanation: ActionPolicyExplanation

    public init(decision: HardPolicyDecision, explanation: ActionPolicyExplanation) {
        self.decision = decision
        self.explanation = explanation
    }
}

/// Pure semantic evaluator. Same typed action + policy → same verdict.
/// Typed gitPush rules match `gitAction` when present; missing git analysis
/// fails closed. `supportingCommand` is never consulted.
public enum ActionPolicyEngine: Sendable {
    public enum Builtin {
        public static let pack = PackID(rawValue: "builtin.action")

        public static let workingTreeDiscard = Deny(
            ruleID: RuleID(pack: pack, pattern: "working-tree-discard"),
            reason: "Discarding working-tree files is a built-in hard deny."
        )

        public static let remoteSharedBranch = Deny(
            ruleID: RuleID(pack: pack, pattern: "remote-shared-branch-mutation"),
            reason: "Remote mutation of a shared branch is a built-in hard deny."
        )

        public static let remoteBranchAsk = Deny(
            ruleID: RuleID(pack: pack, pattern: "remote-branch-mutation"),
            reason: "Remote branch mutation requires a human."
        )

        public static let localBranchCreate = RuleID(pack: pack, pattern: "local-branch-create")

        public static let localBranchCreateReason =
            "Creating a local branch is a built-in hard allow."

        public static let protectedPath = Deny(
            ruleID: RuleID(pack: pack, pattern: "protected-path-mutation"),
            reason: "Mutating a protected host path is a built-in hard deny."
        )

        public static let inRepository = RuleID(pack: pack, pattern: "in-repo-write")

        public static let inRepositoryReason =
            "In-repository filesystem writes are allowed by built-in policy."

        public static let outsideRepository = Deny(
            ruleID: RuleID(pack: pack, pattern: "out-of-repo-write"),
            reason: "Writing outside the repository is a built-in hard deny."
        )

        public static let outsideRepositoryRead = RuleID(pack: pack, pattern: "out-of-repo-read")

        public static let outsideRepositoryReadReason =
            "Reading outside the repository is independently governable."

        public static let unresolvedFilesystem = Deny(
            ruleID: RuleID(pack: pack, pattern: "unresolved-path"),
            reason: "An unresolved repository or path cannot be treated as in-repo."
        )

        public static let uncovered = Deny(
            ruleID: RuleID(pack: pack, pattern: "uncovered"),
            reason: "No semantic rule covered this action."
        )

        public static let packIncomplete = Deny(
            ruleID: RuleID(pack: pack, pattern: "pack-incomplete"),
            reason: "Pack evaluation did not finish."
        )

        public static let unwrapLimited = Deny(
            ruleID: RuleID(pack: pack, pattern: "unwrap-limited"),
            reason: "Wrapper or interpreter nesting could not be analyzed safely."
        )
    }

    public static func evaluate(
        action: ProposedAction,
        context: ReviewContext = ReviewContext(repository: RepositoryReviewContext()),
        policy: EffectiveActionPolicy = .empty,
        gitAction: GitAction? = nil
    ) -> ActionPolicyVerdict {
        switch action {
        case .shell(let shell):
            return evaluateShell(shell, context: context, policy: policy, gitAction: gitAction)
        }
    }

    public static func evaluate(
        _ request: ReviewRequest,
        policy: EffectiveActionPolicy = .empty
    ) -> ActionPolicyVerdict {
        evaluate(action: request.action, context: request.context, policy: policy)
    }

    /// Structural bind: reviewer output is applied only through `ReviewBind`.
    public static func bind(
        action: ProposedAction,
        context: ReviewContext,
        policy: EffectiveActionPolicy = .empty,
        review: Result<ActionReview, ActionReviewerError>
    ) -> BoundReview {
        ReviewBind.apply(
            hardDecision: evaluate(action: action, context: context, policy: policy).decision,
            review: review
        )
    }

    private static func evaluateShell(
        _ shell: ShellAction,
        context: ReviewContext,
        policy: EffectiveActionPolicy,
        gitAction: GitAction?
    ) -> ActionPolicyVerdict {
        var hit = builtinHit(shell: shell, context: context)
        hit = applyTypedRules(hit, policy.rules, gitAction: gitAction)
        if hit.semanticallyCovered == false {
            hit = applyPackFallback(hit, policy.packFallback)
        }
        hit = applyOverlay(hit, policy.overlay)
        return ActionPolicyVerdict(
            decision: hit.decision,
            explanation: ActionPolicyExplanation(
                zone: hit.decision.zone,
                ruleID: hit.ruleID,
                reason: hit.reason
            )
        )
    }

    private static func builtinHit(shell: ShellAction, context: ReviewContext) -> CoreHit {
        let kinds = shell.effects.kinds
        if kinds.contains(.protectedPathMutation) {
            return CoreHit(
                decision: .hardDeny(Builtin.protectedPath),
                ruleID: Builtin.protectedPath.ruleID,
                reason: Builtin.protectedPath.reason,
                semanticallyCovered: true
            )
        }
        if kinds.contains(.workingTreeDiscard) {
            return CoreHit(
                decision: .hardDeny(Builtin.workingTreeDiscard),
                ruleID: Builtin.workingTreeDiscard.ruleID,
                reason: Builtin.workingTreeDiscard.reason,
                semanticallyCovered: true
            )
        }
        if kinds.contains(.remoteSharedBranchMutation) {
            if isSharedTarget(resources: shell.resources, context: context) {
                return CoreHit(
                    decision: .hardDeny(Builtin.remoteSharedBranch),
                    ruleID: Builtin.remoteSharedBranch.ruleID,
                    reason: Builtin.remoteSharedBranch.reason,
                    semanticallyCovered: true
                )
            }
            return CoreHit(
                decision: .mandatoryHuman(Builtin.remoteBranchAsk),
                ruleID: Builtin.remoteBranchAsk.ruleID,
                reason: Builtin.remoteBranchAsk.reason,
                semanticallyCovered: true
            )
        }
        if kinds.contains(.localBranchCreate) {
            return CoreHit(
                decision: .hardAllow,
                ruleID: Builtin.localBranchCreate,
                reason: Builtin.localBranchCreateReason,
                semanticallyCovered: true
            )
        }
        if isFilesystemAction(kinds) {
            return filesystemHit(shell)
        }
        return CoreHit(
            decision: .reviewEligible(fallback: Builtin.uncovered),
            ruleID: Builtin.uncovered.ruleID,
            reason: Builtin.uncovered.reason,
            semanticallyCovered: false
        )
    }

    private static func filesystemHit(_ shell: ShellAction) -> CoreHit {
        let kinds = shell.effects.kinds
        let scope = shell.resources.filesystemScope
        if kinds.contains(.unresolvedFilesystem) || scope == .unknown || scope == nil {
            return CoreHit(
                decision: .hardDeny(Builtin.unresolvedFilesystem),
                ruleID: Builtin.unresolvedFilesystem.ruleID,
                reason: Builtin.unresolvedFilesystem.reason,
                semanticallyCovered: true
            )
        }
        // Scope alone is enough: a write that omitted `.protectedPathMutation`
        // must not fall through to reviewEligible / overlay allow.
        // Reads (`cat ~/.ssh/config`) are intentionally not filesystem-deny;
        // they are still covered by `SecretPathGuard` (core.secrets) when
        // evaluated via `Evaluate`. Guard like `outsideRepository`.
        if kinds.contains(.protectedPathMutation)
            || (isWriteLike(kinds) && scope == .protectedPath)
        {
            return CoreHit(
                decision: .hardDeny(Builtin.protectedPath),
                ruleID: Builtin.protectedPath.ruleID,
                reason: Builtin.protectedPath.reason,
                semanticallyCovered: true
            )
        }
        if kinds.contains(.outsideRepositoryMutation)
            || (isWriteLike(kinds) && scope == .outsideRepository)
        {
            return CoreHit(
                decision: .hardDeny(Builtin.outsideRepository),
                ruleID: Builtin.outsideRepository.ruleID,
                reason: Builtin.outsideRepository.reason,
                semanticallyCovered: true
            )
        }
        if scope == .insideRepository {
            return CoreHit(
                decision: .hardAllow,
                ruleID: Builtin.inRepository,
                reason: Builtin.inRepositoryReason,
                semanticallyCovered: true
            )
        }
        if kinds.contains(.filesystemRead) {
            return CoreHit(
                decision: .hardAllow,
                ruleID: Builtin.outsideRepositoryRead,
                reason: Builtin.outsideRepositoryReadReason,
                semanticallyCovered: true
            )
        }
        return CoreHit(
            decision: .reviewEligible(fallback: Builtin.uncovered),
            ruleID: Builtin.uncovered.ruleID,
            reason: Builtin.uncovered.reason,
            semanticallyCovered: false
        )
    }

    private static func isFilesystemAction(_ kinds: [ActionEffectKind]) -> Bool {
        kinds.contains(where: {
            switch $0 {
            case .filesystemDelete, .filesystemMove, .filesystemOverwrite,
                .filesystemModeChange, .filesystemCreate, .filesystemRead,
                .outsideRepositoryMutation, .unresolvedFilesystem:
                return true
            case .remoteSharedBranchMutation, .localBranchCreate, .workingTreeDiscard,
                .protectedPathMutation:
                return false
            }
        })
    }

    private static func isWriteLike(_ kinds: [ActionEffectKind]) -> Bool {
        kinds.contains(where: {
            switch $0 {
            case .filesystemDelete, .filesystemMove, .filesystemOverwrite, .filesystemModeChange,
                .filesystemCreate, .outsideRepositoryMutation:
                return true
            case .filesystemRead, .remoteSharedBranchMutation, .localBranchCreate,
                .workingTreeDiscard, .protectedPathMutation, .unresolvedFilesystem:
                return false
            }
        })
    }

    private static func isSharedTarget(resources: ActionResources, context: ReviewContext) -> Bool {
        if context.repository.isSharedBranch {
            return true
        }
        if let branch = resources.branchName, Self.sharedBranchNames.contains(branch) {
            return true
        }
        return false
    }

    private static let sharedBranchNames: Set<String> = ["main", "master"]

    /// Restrict-only. Rank is deny > ask > allow, independent of list order.
    /// Ask beats allow when both match. Typed allow cannot loosen a built-in hit.
    private static func applyTypedRules(
        _ hit: CoreHit,
        _ rules: [TypedRule],
        gitAction: GitAction?
    ) -> CoreHit {
        var strongest: TypedRule?
        for rule in rules {
            guard let gitAction, PolicyMatch.matches(rule.predicate, action: gitAction) else {
                continue
            }
            if let current = strongest {
                if typedRestrictionRank(rule.verdict) > typedRestrictionRank(current.verdict) {
                    strongest = rule
                }
            } else {
                strongest = rule
            }
        }
        guard let rule = strongest else {
            return hit
        }
        switch rule.verdict {
        case .deny:
            let deny = Deny(ruleID: rule.id, reason: "A typed rule denied this action.")
            return CoreHit(
                decision: .hardDeny(deny),
                ruleID: rule.id,
                reason: deny.reason,
                semanticallyCovered: true
            )
        case .ask:
            if case .hardDeny = hit.decision {
                return hit
            }
            let deny = Deny(ruleID: rule.id, reason: "A typed rule requires a human.")
            return CoreHit(
                decision: .mandatoryHuman(deny),
                ruleID: rule.id,
                reason: deny.reason,
                semanticallyCovered: true
            )
        case .allow:
            return hit
        }
    }

    private static func typedRestrictionRank(_ verdict: TypedRuleVerdict) -> Int {
        switch verdict {
        case .allow:
            return 0
        case .ask:
            return 1
        case .deny:
            return 2
        }
    }

    private static func applyPackFallback(_ hit: CoreHit, _ fallback: PackFallback) -> CoreHit {
        switch fallback {
        case .none, .allow:
            return hit
        case .deny(let deny):
            return CoreHit(
                decision: .hardDeny(deny),
                ruleID: deny.ruleID,
                reason: deny.reason,
                semanticallyCovered: false
            )
        case .ask(let deny):
            return CoreHit(
                decision: .mandatoryHuman(deny),
                ruleID: deny.ruleID,
                reason: deny.reason,
                semanticallyCovered: false
            )
        }
    }

    private static func applyOverlay(_ hit: CoreHit, _ overlay: ActionPolicyOverlay) -> CoreHit {
        switch overlay {
        case .none, .allow:
            return hit
        case .mandatoryHuman(let deny):
            if case .hardDeny = hit.decision {
                return hit
            }
            return CoreHit(
                decision: .mandatoryHuman(deny),
                ruleID: deny.ruleID,
                reason: deny.reason,
                semanticallyCovered: hit.semanticallyCovered
            )
        case .deny(let deny):
            if case .hardDeny = hit.decision {
                return hit
            }
            return CoreHit(
                decision: .hardDeny(deny),
                ruleID: deny.ruleID,
                reason: deny.reason,
                semanticallyCovered: hit.semanticallyCovered
            )
        }
    }
}

private struct CoreHit: Sendable, Equatable {
    var decision: HardPolicyDecision
    var ruleID: RuleID
    var reason: String
    var semanticallyCovered: Bool
}

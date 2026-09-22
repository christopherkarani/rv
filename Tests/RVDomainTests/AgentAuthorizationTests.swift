import Testing
@testable import RVDomain

@Suite("AgentAuthorization")
struct AgentAuthorizationTests {
    private let shared = ActionPolicyFixtures.sharedContext
    private let privateBranch = ActionPolicyFixtures.privateContext
    private let allowReview = ActionPolicyFixtures.qualifiedAllow
    private let qualifiedDenyReview = ActionReview.make(
        decision: .deny,
        risk: .medium,
        confidence: .high,
        rationale: "stub deny",
        rationaleCategory: .deny
    )

    @Test func inRepoWrite_isAllowedWithInRepositoryExplanation() {
        let write = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite],
            path: "/repo/Sources/Foo.swift",
            scope: .insideRepository
        )
        let create = ActionPolicyFixtures.filesystem(
            effects: [.filesystemCreate],
            path: "/repo/new.swift",
            scope: .insideRepository
        )
        expectAllowed(
            AgentAuthorization.decide(action: write, context: shared, gitWorld: .unprobed),
            action: write,
            ruleID: ActionPolicyEngine.Builtin.inRepository
        )
        expectAllowed(
            AgentAuthorization.decide(action: create, context: shared, gitWorld: .unprobed),
            action: create,
            ruleID: ActionPolicyEngine.Builtin.inRepository
        )
    }

    @Test func forcePushMain_isDeniedRemoteSharedBranch() {
        let action = ActionPolicyFixtures.forcePush()
        expectDenied(
            AgentAuthorization.decide(action: action, context: shared, gitWorld: .unprobed),
            action: action,
            deny: ActionPolicyEngine.Builtin.remoteSharedBranch
        )
    }

    @Test func forcePushTopic_isPendingMandatoryHuman() {
        let action = ActionPolicyFixtures.forcePush(branchName: "topic")
        expectPending(
            AgentAuthorization.decide(action: action, context: privateBranch, gitWorld: .unprobed),
            action: action,
            reason: .mandatoryHuman,
            deny: ActionPolicyEngine.Builtin.remoteBranchAsk
        )
    }

    @Test func workingTreeDiscard_isDenied() {
        let action = ActionPolicyFixtures.checkout(
            effects: [.workingTreeDiscard],
            supportingCommand: "git reset --hard"
        )
        expectDenied(
            AgentAuthorization.decide(action: action, context: shared, gitWorld: .unprobed),
            action: action,
            deny: ActionPolicyEngine.Builtin.workingTreeDiscard
        )
    }

    @Test func outOfRepoWrite_isDeniedOutsideRepository() {
        let action = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite, .outsideRepositoryMutation],
            path: "/tmp/outside-file",
            scope: .outsideRepository
        )
        expectDenied(
            AgentAuthorization.decide(action: action, context: shared, gitWorld: .unprobed),
            action: action,
            deny: ActionPolicyEngine.Builtin.outsideRepository
        )
    }

    @Test func protectedPathWrite_isDeniedProtectedPath() {
        let action = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite],
            path: "/home/.ssh/id_rsa",
            scope: .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh))
        )
        expectDenied(
            AgentAuthorization.decide(action: action, context: shared, gitWorld: .unprobed),
            action: action,
            deny: ActionPolicyEngine.Builtin.protectedPath
        )
    }

    @Test func uncoveredEchoHello_defaultReview_isPendingReviewAsk() {
        let action = ActionPolicyFixtures.uncovered(supportingCommand: "echo hello")
        let authorization = AgentAuthorization.decide(
            action: action,
            context: shared,
            gitWorld: .unprobed
        )
        expectPending(
            authorization,
            action: action,
            reason: .reviewAsk,
            deny: ActionPolicyEngine.Builtin.uncovered
        )
        switch authorization {
        case .allowed:
            Issue.record("missing reviewer on reviewEligible must not produce AllowedAction")
        case .pending, .denied:
            break
        }
    }

    @Test func uncovered_qualifiedAllowReview_isAllowed() {
        let action = ActionPolicyFixtures.uncovered(supportingCommand: "echo hello")
        expectAllowed(
            AgentAuthorization.decide(
                action: action,
                context: shared,
                gitWorld: .unprobed,
                review: .success(allowReview)
            ),
            action: action,
            ruleID: ActionPolicyEngine.Builtin.uncovered.ruleID
        )
    }

    @Test func uncovered_qualifiedDenyReview_isDenied() {
        let action = ActionPolicyFixtures.uncovered(supportingCommand: "echo hello")
        expectDenied(
            AgentAuthorization.decide(
                action: action,
                context: shared,
                gitWorld: .unprobed,
                review: .success(qualifiedDenyReview)
            ),
            action: action,
            deny: ActionPolicyEngine.Builtin.uncovered
        )
    }

    @Test(arguments: [
        AgentAuthorizationReviewStub.lowConfidenceAllow,
        .conflictingAllow,
        .timeout,
    ])
    func uncovered_weakOrConflictingOrFailedReview_isPendingReviewAsk(
        stub: AgentAuthorizationReviewStub
    ) {
        let action = ActionPolicyFixtures.uncovered(supportingCommand: "echo hello")
        expectPending(
            AgentAuthorization.decide(
                action: action,
                context: shared,
                gitWorld: .unprobed,
                review: stub.review
            ),
            action: action,
            reason: .reviewAsk,
            deny: ActionPolicyEngine.Builtin.uncovered
        )
    }

    @Test func hardDeny_stubAllowReview_staysDenied() {
        let action = ActionPolicyFixtures.forcePush()
        expectDenied(
            AgentAuthorization.decide(
                action: action,
                context: shared,
                gitWorld: .unprobed,
                review: .success(allowReview)
            ),
            action: action,
            deny: ActionPolicyEngine.Builtin.remoteSharedBranch
        )
    }

    @Test func inRepoWrite_stubDenyReview_staysAllowed() {
        let write = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite],
            path: "/repo/Sources/Foo.swift",
            scope: .insideRepository
        )
        expectAllowed(
            AgentAuthorization.decide(
                action: write,
                context: shared,
                gitWorld: .unprobed,
                review: .success(qualifiedDenyReview)
            ),
            action: write,
            ruleID: ActionPolicyEngine.Builtin.inRepository
        )
    }

    @Test func forcePushTopic_stubReview_staysPendingMandatoryHuman() {
        let action = ActionPolicyFixtures.forcePush(branchName: "topic")
        expectPending(
            AgentAuthorization.decide(
                action: action,
                context: privateBranch,
                gitWorld: .unprobed,
                review: .success(allowReview)
            ),
            action: action,
            reason: .mandatoryHuman,
            deny: ActionPolicyEngine.Builtin.remoteBranchAsk
        )
        expectPending(
            AgentAuthorization.decide(
                action: action,
                context: privateBranch,
                gitWorld: .unprobed,
                review: .success(qualifiedDenyReview)
            ),
            action: action,
            reason: .mandatoryHuman,
            deny: ActionPolicyEngine.Builtin.remoteBranchAsk
        )
    }

    @Test func map_hardDenyBoundAllow_staysDenied() {
        let action = ActionPolicyFixtures.forcePush()
        let deny = ActionPolicyEngine.Builtin.remoteSharedBranch
        expectDenied(
            AgentAuthorization.map(
                action: action,
                hardDecision: .hardDeny(deny),
                explanation: explanation(zone: .hardDeny, deny: deny),
                bound: .allow
            ),
            action: action,
            deny: deny
        )
    }

    @Test func map_mandatoryHumanBoundDeny_staysPending() {
        let action = ActionPolicyFixtures.forcePush(branchName: "topic")
        let deny = ActionPolicyEngine.Builtin.remoteBranchAsk
        expectPending(
            AgentAuthorization.map(
                action: action,
                hardDecision: .mandatoryHuman(deny),
                explanation: explanation(zone: .mandatoryHuman, deny: deny),
                bound: .deny(deny)
            ),
            action: action,
            reason: .mandatoryHuman,
            deny: deny
        )
    }

    @Test func map_hardAllowBoundDeny_staysAllowed() {
        let write = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite],
            path: "/repo/Sources/Foo.swift",
            scope: .insideRepository
        )
        let deny = ActionPolicyEngine.Builtin.uncovered
        expectAllowed(
            AgentAuthorization.map(
                action: write,
                hardDecision: .hardAllow,
                explanation: ActionPolicyExplanation(
                    zone: .hardAllow,
                    ruleID: ActionPolicyEngine.Builtin.inRepository,
                    reason: ActionPolicyEngine.Builtin.inRepositoryReason
                ),
                bound: .deny(deny)
            ),
            action: write,
            ruleID: ActionPolicyEngine.Builtin.inRepository
        )
    }

    @Test func boundReviewDecision_onPending_isPackDeny_runtimeStaysPending() {
        let action = ActionPolicyFixtures.forcePush(branchName: "topic")
        let authorization = AgentAuthorization.decide(
            action: action,
            context: privateBranch,
            gitWorld: .unprobed
        )
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: privateBranch,
            policy: .empty,
            gitWorld: .unprobed
        )
        let bound = ReviewBind.apply(
            hardDecision: verdict.decision,
            review: .failure(.unsupported)
        )
        #expect(bound == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
        #expect(bound.decision == .deny(ActionPolicyEngine.Builtin.remoteBranchAsk))
        expectPending(
            authorization,
            action: action,
            reason: .mandatoryHuman,
            deny: ActionPolicyEngine.Builtin.remoteBranchAsk
        )
        switch authorization {
        case .denied:
            Issue.record("BoundReview.decision pack-deny must not become AgentAuthorization.denied")
        case .allowed:
            Issue.record("pending must not collapse to allowed")
        case .pending:
            break
        }
    }

    @Test func hookBoundQuietAllow_isNotTheRuntimeDoor() {
        let action = ActionPolicyFixtures.uncovered(supportingCommand: "echo hello")
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: .empty,
            gitWorld: .unprobed
        )
        #expect(verdict.decision == .reviewEligible(fallback: ActionPolicyEngine.Builtin.uncovered))
        #expect(HostNativeAsk.hookBound(verdict.decision) == .allow)
        let authorization = AgentAuthorization.decide(
            action: action,
            context: shared,
            gitWorld: .unprobed
        )
        expectPending(
            authorization,
            action: action,
            reason: .reviewAsk,
            deny: ActionPolicyEngine.Builtin.uncovered
        )
        switch authorization {
        case .allowed:
            Issue.record("runtime decide must not inherit hookBound quiet allow")
        case .pending, .denied:
            break
        }
    }

    @Test func implicitForcePush_unprobedDefault_isPendingNotProbedSharedDeny() {
        let action = ActionPolicyFixtures.implicitForcePush()
        let probed = ActionPolicyEngine.evaluate(action: action, context: shared)
        #expect(probed.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        expectPending(
            AgentAuthorization.decide(action: action, context: shared),
            action: action,
            reason: .reviewAsk,
            deny: ActionPolicyEngine.Builtin.uncovered
        )
    }

    @Test func overlayAllow_cannotLiftProtectedPath() {
        let action = ActionPolicyFixtures.filesystem(
            effects: [.filesystemDelete, .protectedPathMutation],
            path: "/home/.ssh/id_rsa",
            scope: .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh))
        )
        expectDenied(
            AgentAuthorization.decide(
                action: action,
                context: shared,
                policy: EffectiveActionPolicy(overlay: .allow),
                gitWorld: .unprobed
            ),
            action: action,
            deny: ActionPolicyEngine.Builtin.protectedPath
        )
    }

    @Test func decide_doesNotRequirePacksOrPolicyGate() {
        let action = ActionPolicyFixtures.uncovered(supportingCommand: "git status")
        let authorization = AgentAuthorization.decide(action: action, gitWorld: .unprobed)
        expectPending(
            authorization,
            action: action,
            reason: .reviewAsk,
            deny: ActionPolicyEngine.Builtin.uncovered
        )
    }

    @Test func pendingReason_isNeverHostAsk() {
        let uncovered = AgentAuthorization.decide(
            action: ActionPolicyFixtures.uncovered(supportingCommand: "echo hello"),
            context: shared,
            gitWorld: .unprobed
        )
        let topic = AgentAuthorization.decide(
            action: ActionPolicyFixtures.forcePush(branchName: "topic"),
            context: privateBranch,
            gitWorld: .unprobed
        )
        switch uncovered {
        case .pending(let pending):
            #expect(pending.reason == .reviewAsk)
        case .allowed, .denied:
            Issue.record("uncovered default review must be pending")
        }
        switch topic {
        case .pending(let pending):
            #expect(pending.reason == .mandatoryHuman)
        case .allowed, .denied:
            Issue.record("topic force-push must be pending")
        }
    }

    @Test func payloadInits_areTestSeamsNotProductionMints() {
        let action = ActionPolicyFixtures.uncovered(supportingCommand: "echo hello")
        let explanation = ActionPolicyExplanation(
            zone: .reviewEligible,
            ruleID: ActionPolicyEngine.Builtin.uncovered.ruleID,
            reason: ActionPolicyEngine.Builtin.uncovered.reason
        )
        let mintedAllow = AllowedAction(action: action, explanation: explanation)
        let mintedDeny = DeniedAction(
            action: action,
            deny: ActionPolicyEngine.Builtin.uncovered,
            explanation: explanation
        )
        let mintedPending = PendingAuthorization(
            action: action,
            reason: .reviewAsk,
            deny: ActionPolicyEngine.Builtin.uncovered,
            explanation: explanation
        )
        #expect(mintedAllow.action == action)
        #expect(mintedDeny.deny == ActionPolicyEngine.Builtin.uncovered)
        #expect(mintedPending.reason == .reviewAsk)
        expectPending(
            AgentAuthorization.decide(action: action, context: shared, gitWorld: .unprobed),
            action: action,
            reason: .reviewAsk,
            deny: ActionPolicyEngine.Builtin.uncovered
        )
    }
}

enum AgentAuthorizationReviewStub: Sendable {
    case lowConfidenceAllow
    case conflictingAllow
    case timeout

    var review: Result<ActionReview, ActionReviewerError> {
        switch self {
        case .lowConfidenceAllow:
            return .success(
                ActionReview.make(
                    decision: .allow,
                    risk: .low,
                    confidence: .low,
                    rationale: "weak allow",
                    rationaleCategory: .allow
                )
            )
        case .conflictingAllow:
            return .success(
                ActionReview.make(
                    decision: .allow,
                    risk: .low,
                    confidence: .high,
                    rationale: "allow with deny rationale",
                    rationaleCategory: .deny
                )
            )
        case .timeout:
            return .failure(.timeout)
        }
    }
}

private func explanation(zone: ActionPolicyZone, deny: Deny) -> ActionPolicyExplanation {
    ActionPolicyExplanation(zone: zone, ruleID: deny.ruleID, reason: deny.reason)
}

private func expectAllowed(
    _ authorization: AgentAuthorization,
    action: ProposedAction,
    ruleID: RuleID,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch authorization {
    case .allowed(let allowed):
        #expect(allowed.action == action, sourceLocation: sourceLocation)
        #expect(allowed.explanation.ruleID == ruleID, sourceLocation: sourceLocation)
        switch allowed.explanation.zone {
        case .hardAllow, .reviewEligible:
            break
        case .hardDeny, .mandatoryHuman:
            Issue.record(
                "allowed payload must not carry zone \(allowed.explanation.zone)",
                sourceLocation: sourceLocation
            )
        }
    case .pending(let pending):
        Issue.record(
            "expected allowed, got pending \(pending.reason)",
            sourceLocation: sourceLocation
        )
    case .denied(let denied):
        Issue.record(
            "expected allowed, got denied \(denied.deny.ruleID)",
            sourceLocation: sourceLocation
        )
    }
}

private func expectPending(
    _ authorization: AgentAuthorization,
    action: ProposedAction,
    reason: RuntimeAskReason,
    deny: Deny,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch authorization {
    case .pending(let pending):
        #expect(pending.action == action, sourceLocation: sourceLocation)
        #expect(pending.reason == reason, sourceLocation: sourceLocation)
        #expect(pending.deny == deny, sourceLocation: sourceLocation)
    case .allowed:
        Issue.record("expected pending, got allowed", sourceLocation: sourceLocation)
    case .denied(let denied):
        Issue.record(
            "expected pending, got denied \(denied.deny.ruleID)",
            sourceLocation: sourceLocation
        )
    }
}

private func expectDenied(
    _ authorization: AgentAuthorization,
    action: ProposedAction,
    deny: Deny,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch authorization {
    case .denied(let denied):
        #expect(denied.action == action, sourceLocation: sourceLocation)
        #expect(denied.deny == deny, sourceLocation: sourceLocation)
    case .allowed:
        Issue.record("expected denied, got allowed", sourceLocation: sourceLocation)
    case .pending(let pending):
        Issue.record(
            "expected denied, got pending \(pending.reason)",
            sourceLocation: sourceLocation
        )
    }
}

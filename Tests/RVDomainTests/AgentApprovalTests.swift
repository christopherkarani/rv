import Testing
@testable import RVDomain

@Suite("AgentApproval")
struct AgentApprovalTests {
    @Test func resolve_mandatoryHuman_allowOnce_isAllowed() throws {
        let pending = try requireTopicForcePushPending()
        expectAllowedResolved(
            AgentAuthorization.resolve(pending, approval: .success(.allowOnce)),
            pending: pending
        )
    }

    @Test func resolve_mandatoryHuman_deny_isDenied() throws {
        let pending = try requireTopicForcePushPending()
        expectDeniedResolved(
            AgentAuthorization.resolve(pending, approval: .success(.deny)),
            pending: pending
        )
    }

    @Test func resolve_reviewAsk_allowOnce_isAllowed() throws {
        let pending = try requireUncoveredPending()
        expectAllowedResolved(
            AgentAuthorization.resolve(pending, approval: .success(.allowOnce)),
            pending: pending
        )
    }

    @Test func resolve_reviewAsk_deny_isDenied() throws {
        let pending = try requireUncoveredPending()
        #expect(pending.deny == ActionPolicyEngine.Builtin.uncovered)
        expectDeniedResolved(
            AgentAuthorization.resolve(pending, approval: .success(.deny)),
            pending: pending
        )
    }

    @Test func resolve_createRule_fails() throws {
        let pending = try requireTopicForcePushPending()
        expectResolveFailure(
            AgentAuthorization.resolve(pending, approval: .success(.createRule)),
            .ruleCreationUnsupported
        )
    }

    @Test func resolve_approvalUnavailable_fails() throws {
        let pending = try requireTopicForcePushPending()
        expectResolveFailure(
            AgentAuthorization.resolve(pending, approval: .failure(.approvalUnavailable)),
            .approvalUnavailable
        )
    }

    @Test func resolve_hostAsk_fails() throws {
        let decided = try requireUncoveredPending()
        let pending = PendingAuthorization(
            action: decided.action,
            reason: .hostAsk,
            deny: decided.deny,
            explanation: decided.explanation
        )
        expectResolveFailure(
            AgentAuthorization.resolve(pending, approval: .success(.allowOnce)),
            .hostAskUnsupported
        )
    }

    @Test func resolve_deniedCannotBeInput() {
        // DeniedAction cannot be approved. There is no
        // `AgentAuthorization.resolve(_: DeniedAction, ...)` or
        // `resolve(_: ProposedAction, ...)` overload. The human door
        // accepts `PendingAuthorization` only.
        let action = ActionPolicyFixtures.forcePush()
        switch AgentAuthorization.decide(
            action: action,
            context: ActionPolicyFixtures.sharedContext,
            gitWorld: .unprobed
        ) {
        case .denied:
            break
        case .allowed:
            Issue.record("shared-branch force-push must be denied, not allowed")
        case .pending:
            Issue.record("shared-branch force-push must be denied, not pending")
        }
    }

    @Test func decide_stillDoesNotLiftMandatoryHuman() throws {
        let action = ActionPolicyFixtures.forcePush(branchName: "topic")
        let authorization = AgentAuthorization.decide(
            action: action,
            context: ActionPolicyFixtures.privateContext,
            gitWorld: .unprobed,
            review: .success(ActionPolicyFixtures.qualifiedAllow)
        )
        let pending = try requirePending(authorization, reason: .mandatoryHuman)
        #expect(pending.action == action)
        #expect(pending.deny == ActionPolicyEngine.Builtin.remoteBranchAsk)
        switch authorization {
        case .allowed:
            Issue.record("qualified allow review must not lift mandatoryHuman")
        case .pending, .denied:
            break
        }
    }
}

private func requireTopicForcePushPending() throws -> PendingAuthorization {
    let action = ActionPolicyFixtures.forcePush(branchName: "topic")
    let pending = try requirePending(
        AgentAuthorization.decide(
            action: action,
            context: ActionPolicyFixtures.privateContext,
            gitWorld: .unprobed,
            review: .success(ActionPolicyFixtures.qualifiedAllow)
        ),
        reason: .mandatoryHuman
    )
    #expect(pending.action == action)
    #expect(pending.action.fingerprint == action.fingerprint)
    #expect(pending.deny == ActionPolicyEngine.Builtin.remoteBranchAsk)
    return pending
}

private func requireUncoveredPending() throws -> PendingAuthorization {
    let action = ActionPolicyFixtures.uncovered(supportingCommand: "echo hello")
    let pending = try requirePending(
        AgentAuthorization.decide(
            action: action,
            context: ActionPolicyFixtures.sharedContext,
            gitWorld: .unprobed
        ),
        reason: .reviewAsk
    )
    #expect(pending.action == action)
    #expect(pending.deny == ActionPolicyEngine.Builtin.uncovered)
    return pending
}

private func requirePending(
    _ authorization: AgentAuthorization,
    reason: ApprovalReason,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> PendingAuthorization {
    switch authorization {
    case .pending(let pending):
        #expect(pending.reason == reason, sourceLocation: sourceLocation)
        #expect(pending.reason != .hostAsk, sourceLocation: sourceLocation)
        return pending
    case .allowed:
        Issue.record(
            "expected pending \(reason), got allowed",
            sourceLocation: sourceLocation
        )
        throw AgentApprovalFixtureError.expectedPending
    case .denied(let denied):
        Issue.record(
            "expected pending \(reason), got denied \(denied.deny.ruleID)",
            sourceLocation: sourceLocation
        )
        throw AgentApprovalFixtureError.expectedPending
    }
}

private func expectAllowedResolved(
    _ result: Result<ResolvedAuthorization, AgentApprovalError>,
    pending: PendingAuthorization,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success(.allowed(let allowed)):
        #expect(allowed.action == pending.action, sourceLocation: sourceLocation)
        #expect(
            allowed.action.fingerprint == pending.action.fingerprint,
            sourceLocation: sourceLocation
        )
        #expect(allowed.explanation == pending.explanation, sourceLocation: sourceLocation)
    case .success(.denied(let denied)):
        Issue.record(
            "expected allowed, got denied \(denied.deny.ruleID)",
            sourceLocation: sourceLocation
        )
    case .failure(let error):
        Issue.record("expected allowed, got \(error)", sourceLocation: sourceLocation)
    }
}

private func expectDeniedResolved(
    _ result: Result<ResolvedAuthorization, AgentApprovalError>,
    pending: PendingAuthorization,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success(.denied(let denied)):
        #expect(denied.action == pending.action, sourceLocation: sourceLocation)
        #expect(denied.deny == pending.deny, sourceLocation: sourceLocation)
        #expect(denied.explanation == pending.explanation, sourceLocation: sourceLocation)
    case .success(.allowed):
        Issue.record("expected denied, got AllowedAction", sourceLocation: sourceLocation)
    case .failure(let error):
        Issue.record("expected denied, got \(error)", sourceLocation: sourceLocation)
    }
}

private func expectResolveFailure(
    _ result: Result<ResolvedAuthorization, AgentApprovalError>,
    _ expected: AgentApprovalError,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success(.allowed):
        Issue.record(
            "expected \(expected), got AllowedAction",
            sourceLocation: sourceLocation
        )
    case .success(.denied(let denied)):
        Issue.record(
            "expected \(expected), got denied \(denied.deny.ruleID)",
            sourceLocation: sourceLocation
        )
    case .failure(let error):
        #expect(error == expected, sourceLocation: sourceLocation)
    }
}

private enum AgentApprovalFixtureError: Error {
    case expectedPending
}

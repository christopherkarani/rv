import Testing
import RVDomain
@testable import RVEngine

@Suite("NormalizeThenAuthorize")
struct NormalizeThenAuthorizeTests {
    private let repo = FilesystemAnalysisWorld.probed(
        FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo")
        )
    )

    @Test func gitResetHard_isDeniedWorkingTreeDiscard() throws {
        let action = try requireProposedAction(
            normalizeAgentRequest(try processRequest("git reset --hard"))
        )
        expectDenied(
            AgentAuthorization.decide(action: action, gitWorld: .unprobed),
            deny: ActionPolicyEngine.Builtin.workingTreeDiscard
        )
    }

    @Test(arguments: ["echo hello", "git status"])
    func benignCommand_isPendingReviewAsk(_ command: String) throws {
        let action = try requireProposedAction(
            normalizeAgentRequest(try processRequest(command))
        )
        expectPending(
            AgentAuthorization.decide(action: action, gitWorld: .unprobed),
            reason: .reviewAsk,
            deny: ActionPolicyEngine.Builtin.uncovered
        )
    }

    @Test func probedInRepoWrite_isAllowed() throws {
        let action = try requireProposedAction(
            normalizeAgentRequest(
                try processRequest("echo hi > file"),
                filesystemWorld: repo
            )
        )
        #expect(action.resources.filesystemScope == .insideRepository)
        expectAllowed(
            AgentAuthorization.decide(action: action, gitWorld: .unprobed),
            ruleID: ActionPolicyEngine.Builtin.inRepository
        )
    }

    @Test func protectedPathDelete_isDenied() throws {
        let action = try requireProposedAction(
            normalizeAgentRequest(try processRequest("env -C /tmp/.ssh rm config"))
        )
        expectDenied(
            AgentAuthorization.decide(action: action, gitWorld: .unprobed),
            deny: ActionPolicyEngine.Builtin.protectedPath
        )
    }

    @Test(arguments: [
        "bash -c git reset --hard",
        "zsh -c $CMD",
    ])
    func unwrapLimited_stopsBeforeAuthorize(_ command: String) throws {
        let result = normalizeAgentRequest(try processRequest(command))
        #expect(result == .failure(.unwrapLimited))
        switch result {
        case .success:
            Issue.record("unwrap-limited must not produce ProposedAction or AllowedAction")
        case .failure:
            break
        }
    }

    @Test func compose_doesNotRequirePacksOrPolicyGate() throws {
        let action = try requireProposedAction(
            normalizeAgentRequest(try processRequest("echo hello"))
        )
        expectPending(
            AgentAuthorization.decide(action: action, gitWorld: .unprobed),
            reason: .reviewAsk,
            deny: ActionPolicyEngine.Builtin.uncovered
        )
    }
}

private func processRequest(
    _ command: String,
    host: HookHost = .opencode
) throws -> AgentRequest {
    try AgentRequest.validate(
        .process(RawAgentProcessRequest(host: host, command: command))
    ).get()
}

private func requireProposedAction(
    _ result: Result<ProposedAction, AgentNormalizationError>,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> ProposedAction {
    switch result {
    case .success(let action):
        return action
    case .failure(let error):
        Issue.record("expected ProposedAction, got \(error)", sourceLocation: sourceLocation)
        throw error
    }
}

private func expectAllowed(
    _ authorization: AgentAuthorization,
    ruleID: RuleID,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch authorization {
    case .allowed(let allowed):
        #expect(allowed.explanation.ruleID == ruleID, sourceLocation: sourceLocation)
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
    reason: RuntimeAskReason,
    deny: Deny,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch authorization {
    case .pending(let pending):
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
    deny: Deny,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch authorization {
    case .denied(let denied):
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

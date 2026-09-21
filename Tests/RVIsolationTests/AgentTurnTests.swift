import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Agent turn dispatch this suite encodes before production code:
/// 1. empty-effect in-workspace `touch` stays pending; `perform` without
///    approval is `awaitingApproval` and does not spawn
/// 2. shared-main `forcePush` is denied and does not spawn
/// 3. in-repo contained `touch` executes, exit 0, file exists
/// 4. pending + `allowOnce` compiles and runs the uncovered `touch`
/// 5. pending + `deny` is denied and does not spawn
/// 6. pending + `approvalUnavailable` is `.failure(.approval)`; file absent
/// 7. pending + `createRule` is `.approval(.ruleCreationUnsupported)`
/// 8. observed plan `containedIsolation()` is `.notContained`, so perform cannot take it
/// 9. second `perform` of the same allowed fingerprint is `.alreadyExecuted`
/// Authorizations are built through `decide`. Spawn is only `perform`.
@Suite("AgentTurn")
struct AgentTurnTests {
    @Test func perform_pendingWithoutApproval_awaitsAndDoesNotSpawn() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("pending-no-approval.txt").path
        let authorization = AgentAuthorization.decide(
            action: try uncoveredTouch(
                path: inside,
                workingDirectory: workspace,
                fingerprint: "shell:agent-turn:pending-no-approval"
            )
        )
        let pending = try requirePendingReviewAsk(authorization)
        let turn = await LocalExecutor().perform(authorization, plan: try tree.requireContainedIsolation())
        switch turn {
        case .success(.awaitingApproval(let waiting)):
            #expect(waiting == pending)
        case .success(.executed):
            Issue.record("pending without approval must not execute")
        case .success(.denied):
            Issue.record("pending without approval must await, not deny")
        case .failure(let error):
            recordUnexpectedTurnError(error, expected: "awaitingApproval")
        }
        #expect(FileManager.default.fileExists(atPath: inside) == false)
    }

    @Test func perform_denied_doesNotSpawn() async throws {
        let action = forcePushMain()
        let authorization = AgentAuthorization.decide(
            action: action,
            context: sharedMainContext,
            gitWorld: .unprobed
        )
        let denied = try requireDenied(authorization)
        let workspace = try #require(WorkingDirectory(validating: "/tmp/rv"))
        let isolation = try requireContainedIsolation(workspace: workspace)
        let turn = await LocalExecutor().perform(authorization, plan: isolation)
        switch turn {
        case .success(.denied(let result)):
            #expect(result == denied)
            #expect(result.deny == ActionPolicyEngine.Builtin.remoteSharedBranch)
        case .success(.executed):
            Issue.record("denied must not execute")
        case .success(.awaitingApproval):
            Issue.record("denied must not await approval")
        case .failure(let error):
            recordUnexpectedTurnError(error, expected: "denied")
        }
    }

    @Test func perform_allowed_containedInWorkspaceWrite() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("allowed.txt").path
        let authorization = try decideAllowedInRepoTouch(
            path: inside,
            workingDirectory: workspace,
            fingerprint: "shell:agent-turn:allowed-in"
        )
        let turn = await LocalExecutor().perform(authorization, plan: try tree.requireContainedIsolation())
        try expectExecutedContained(turn, matching: tree.contained)
        #expect(FileManager.default.fileExists(atPath: inside))
    }

    @Test func perform_pendingAllowOnce_containedInWorkspaceWrite() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("pending-allow-once.txt").path
        let authorization = AgentAuthorization.decide(
            action: try uncoveredTouch(
                path: inside,
                workingDirectory: workspace,
                fingerprint: "shell:agent-turn:pending-allow-once"
            )
        )
        _ = try requirePendingReviewAsk(authorization)
        let turn = await LocalExecutor().perform(
            authorization,
            plan: try tree.requireContainedIsolation(),
            approval: .success(.allowOnce)
        )
        try expectExecutedContained(turn, matching: tree.contained)
        #expect(FileManager.default.fileExists(atPath: inside))
    }

    @Test func perform_pendingDeny_doesNotSpawn() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("pending-deny.txt").path
        let authorization = AgentAuthorization.decide(
            action: try uncoveredTouch(
                path: inside,
                workingDirectory: workspace,
                fingerprint: "shell:agent-turn:pending-deny"
            )
        )
        let pending = try requirePendingReviewAsk(authorization)
        let turn = await LocalExecutor().perform(
            authorization,
            plan: try tree.requireContainedIsolation(),
            approval: .success(.deny)
        )
        switch turn {
        case .success(.denied(let denied)):
            #expect(denied.action == pending.action)
            #expect(denied.deny == pending.deny)
        case .success(.executed):
            Issue.record("pending deny must not execute")
        case .success(.awaitingApproval):
            Issue.record("pending deny must not keep awaiting")
        case .failure(let error):
            recordUnexpectedTurnError(error, expected: "denied")
        }
        #expect(FileManager.default.fileExists(atPath: inside) == false)
    }

    @Test func perform_pendingUnavailable_fails() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("pending-unavailable.txt").path
        let authorization = AgentAuthorization.decide(
            action: try uncoveredTouch(
                path: inside,
                workingDirectory: workspace,
                fingerprint: "shell:agent-turn:pending-unavailable"
            )
        )
        _ = try requirePendingReviewAsk(authorization)
        let turn = await LocalExecutor().perform(
            authorization,
            plan: try tree.requireContainedIsolation(),
            approval: .failure(.approvalUnavailable)
        )
        expectApprovalFailure(turn, .approvalUnavailable)
        #expect(FileManager.default.fileExists(atPath: inside) == false)
    }

    @Test func perform_pendingCreateRule_fails() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("pending-create-rule.txt").path
        let authorization = AgentAuthorization.decide(
            action: try uncoveredTouch(
                path: inside,
                workingDirectory: workspace,
                fingerprint: "shell:agent-turn:pending-create-rule"
            )
        )
        _ = try requirePendingReviewAsk(authorization)
        let turn = await LocalExecutor().perform(
            authorization,
            plan: try tree.requireContainedIsolation(),
            approval: .success(.createRule)
        )
        expectApprovalFailure(turn, .ruleCreationUnsupported)
        #expect(FileManager.default.fileExists(atPath: inside) == false)
    }

    @Test func observedPlan_containedIsolation_fails() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        #expect(tree.observed.containedIsolation() == .failure(.notContained))
        let workspace = try #require(tree.observed.workspace)
        let mediated = try ContainmentTree.requirePlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        #expect(mediated.containedIsolation() == .failure(.notContained))
    }

    @Test func perform_sameFingerprint_secondTurnFails() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("once.txt").path
        let authorization = try decideAllowedInRepoTouch(
            path: inside,
            workingDirectory: workspace,
            fingerprint: "shell:agent-turn:once"
        )
        let allowed = try requireAllowed(authorization)
        let executor = LocalExecutor()
        let first = await executor.perform(authorization, plan: try tree.requireContainedIsolation())
        try expectExecutedContained(first, matching: tree.contained)
        #expect(FileManager.default.fileExists(atPath: inside))
        let second = await executor.perform(authorization, plan: try tree.requireContainedIsolation())
        switch second {
        case .failure(.execute(.alreadyExecuted(let fingerprint))):
            #expect(fingerprint == allowed.action.fingerprint)
        case .failure(let error):
            recordUnexpectedTurnError(error, expected: "alreadyExecuted")
        case .success(.executed):
            Issue.record("second perform of the same fingerprint must not execute")
        case .success(.awaitingApproval):
            Issue.record("second perform must not await approval")
        case .success(.denied):
            Issue.record("second perform must not deny")
        }
    }
}

private let safeTouchExecutables = ["/usr/bin/touch", "/bin/touch"]

private let sharedMainContext = ReviewContext(
    repository: RepositoryReviewContext(
        name: "rv",
        currentBranch: "main"
    )
)

private enum AgentTurnFixtureError: Error {
    case expectedAllowed
    case expectedDenied
    case expectedExecuted
    case expectedPending
    case missingTouch
}

private func forcePushMain() -> ProposedAction {
    .shell(
        ShellAction(
            fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:main"),
            effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
            resources: ActionResources(remoteName: "origin", branchName: "main"),
            scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
            supportingCommand: ShellCommand(rawValue: "git push --force origin main")
        )
    )
}

private func uncoveredTouch(
    path: String,
    workingDirectory: WorkingDirectory,
    fingerprint: String
) throws -> ProposedAction {
    let touch = try requireTouchExecutable()
    return .shell(
        ShellAction(
            fingerprint: ActionFingerprint(rawValue: fingerprint),
            effects: ActionEffects(),
            scope: ActionScope(workingDirectory: workingDirectory),
            supportingCommand: ShellCommand(rawValue: "\(touch) \(path)")
        )
    )
}

private func decideAllowedInRepoTouch(
    path: String,
    workingDirectory: WorkingDirectory,
    fingerprint: String
) throws -> AgentAuthorization {
    let touch = try requireTouchExecutable()
    let authorization = AgentAuthorization.decide(
        action: .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: fingerprint),
                effects: ActionEffects(kinds: [.filesystemCreate]),
                resources: ActionResources(
                    path: path,
                    filesystemScope: .insideRepository,
                    resourceKind: .unknown
                ),
                scope: ActionScope(workingDirectory: workingDirectory),
                supportingCommand: ShellCommand(rawValue: "\(touch) \(path)")
            )
        )
    )
    _ = try requireAllowed(authorization)
    return authorization
}

private func requirePendingReviewAsk(_ authorization: AgentAuthorization) throws -> PendingAuthorization {
    switch authorization {
    case .pending(let pending):
        #expect(pending.reason == .reviewAsk)
        return pending
    case .allowed:
        Issue.record("empty-effect uncovered must stay pending reviewAsk")
        throw AgentTurnFixtureError.expectedPending
    case .denied(let denied):
        Issue.record("empty-effect uncovered must stay pending, got denied \(denied.deny.ruleID)")
        throw AgentTurnFixtureError.expectedPending
    }
}

private func requireAllowed(_ authorization: AgentAuthorization) throws -> AllowedAction {
    switch authorization {
    case .allowed(let allowed):
        return allowed
    case .pending(let pending):
        Issue.record("expected allowed, got pending \(pending.reason)")
        throw AgentTurnFixtureError.expectedAllowed
    case .denied(let denied):
        Issue.record("expected allowed, got denied \(denied.deny.ruleID)")
        throw AgentTurnFixtureError.expectedAllowed
    }
}

private func requireDenied(_ authorization: AgentAuthorization) throws -> DeniedAction {
    switch authorization {
    case .denied(let denied):
        return denied
    case .allowed:
        Issue.record("shared-branch force-push must be denied, not allowed")
        throw AgentTurnFixtureError.expectedDenied
    case .pending:
        Issue.record("shared-branch force-push must be denied, not pending")
        throw AgentTurnFixtureError.expectedDenied
    }
}

private func requireContainedIsolation(workspace: WorkingDirectory) throws -> ContainedIsolation {
    switch compileContainedIsolation(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ) {
    case .success(let isolation):
        return isolation
    case .failure(let error):
        switch error {
        case .containedRequiresWorkspace:
            Issue.record("fixture compile must not fail containedRequiresWorkspace")
            throw error
        case .notContainedRequest:
            Issue.record("fixture compile must not fail notContainedRequest")
            throw error
        }
    }
}

private func requireTouchExecutable() throws -> String {
    for path in safeTouchExecutables where FileManager.default.fileExists(atPath: path) {
        return path
    }
    Issue.record("neither /usr/bin/touch nor /bin/touch exists")
    throw AgentTurnFixtureError.missingTouch
}

private func expectExecutedContained(
    _ turn: Result<AgentTurn, AgentTurnError>,
    matching plan: IsolationPlan,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    switch turn {
    case .success(.executed(let result)):
        #expect(result.exitStatus == 0, sourceLocation: sourceLocation)
        expectContainedPlatform(result.established, matching: plan, sourceLocation: sourceLocation)
    case .success(.awaitingApproval):
        Issue.record("expected executed, got awaitingApproval", sourceLocation: sourceLocation)
        throw AgentTurnFixtureError.expectedExecuted
    case .success(.denied):
        Issue.record("expected executed, got denied", sourceLocation: sourceLocation)
        throw AgentTurnFixtureError.expectedExecuted
    case .failure(let error):
        recordUnexpectedTurnError(error, expected: "executed", sourceLocation: sourceLocation)
        throw AgentTurnFixtureError.expectedExecuted
    }
}

private func expectApprovalFailure(
    _ turn: Result<AgentTurn, AgentTurnError>,
    _ expected: AgentApprovalError,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch turn {
    case .failure(.approval(let error)):
        #expect(error == expected, sourceLocation: sourceLocation)
    case .failure(let error):
        recordUnexpectedTurnError(
            error,
            expected: "approval(\(expected))",
            sourceLocation: sourceLocation
        )
    case .success(.executed):
        Issue.record("approval failure must not execute", sourceLocation: sourceLocation)
    case .success(.awaitingApproval):
        Issue.record("approval failure must not await", sourceLocation: sourceLocation)
    case .success(.denied):
        Issue.record("approval failure must not deny", sourceLocation: sourceLocation)
    }
}

private func expectContainedPlatform(
    _ established: EstablishedIsolation,
    matching plan: IsolationPlan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(established.mode == plan.mode, sourceLocation: sourceLocation)
    switch established.mode {
    case .contained:
        break
    case .observed:
        Issue.record("contained run must not establish observed", sourceLocation: sourceLocation)
    case .mediated:
        Issue.record("contained run must not establish mediated", sourceLocation: sourceLocation)
    }
    #if os(macOS)
    switch established.family {
    case .seatbelt:
        break
    case .none:
        Issue.record("Darwin contained establish must be family seatbelt", sourceLocation: sourceLocation)
    case .landlock:
        Issue.record(
            "Darwin contained establish must be family seatbelt, not landlock",
            sourceLocation: sourceLocation
        )
    }
    #elseif os(Linux)
    switch established.family {
    case .landlock:
        break
    case .none:
        Issue.record("Linux contained establish must be family landlock", sourceLocation: sourceLocation)
    case .seatbelt:
        Issue.record(
            "Linux contained establish must be family landlock, not seatbelt",
            sourceLocation: sourceLocation
        )
    }
    #else
    Issue.record("first-slice LocalExecutor requires Darwin or Linux", sourceLocation: sourceLocation)
    #endif
}

private func recordUnexpectedTurnError(
    _ error: AgentTurnError,
    expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch error {
    case .approval(let approval):
        Issue.record("expected \(expected), got approval \(approval)", sourceLocation: sourceLocation)
    case .compile(let compile):
        Issue.record("expected \(expected), got compile \(compile)", sourceLocation: sourceLocation)
    case .execute(let execute):
        Issue.record("expected \(expected), got execute \(execute)", sourceLocation: sourceLocation)
    }
}


import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Local executor compile + apply edges this suite encodes before production code:
/// 1. `compileExecutable` of decide-allow `echo hi > file` is `commandNotSimpleArgv`
///    (policy allow is not argv)
/// 2. `ProposedAction.file` is `fileActionUnsupported`
/// 3. shell without `supportingCommand` is `missingCommand`
/// 4. bare `touch` resolves only `/usr/bin` then `/bin`
/// 5. unknown bare name is `executableNotResolved`
/// 6. allowed cwd `/a` + plan workspace `/b` is `workspaceMismatch`
/// 7. nil action cwd or nil plan workspace is `workingDirectoryRequired`
/// 8. absolute `/usr/bin/touch` or `/bin/touch` + matching contained plan compiles
/// 9. contained in-workspace `touch` establishes platform contained, exit 0, file exists
/// 10. contained outside `touch` stays contained, file absent, exit != 0
/// 11. observed plan `run` throws `applyFailed(.backendUnavailable)`
/// 12. second `run` of the same fingerprint throws `alreadyExecuted`
/// 13. rejected non-contained intent does not dispatch or consume the fingerprint
/// 14. uncovered in-workspace `touch` (empty effects → reviewAsk) →
///     resolve(allowOnce) → compileExecutable → contained run creates the file
/// `compileExecutable(allowed:plan:)` takes `AllowedAction` only.
/// `LocalExecutor.run` takes `ExecutableAction` only.
/// There is no `PendingAuthorization` or `DeniedAction` overload.
/// A decide → pending fixture has no call path into `run`.
@Suite("LocalExecutor")
struct LocalExecutorTests {
    @Test func compileExecutable_redirect_fails() throws {
        let workspace = try requireWorkspace("/tmp/rv")
        let allowed = try requireAllowed(
            inRepoWrite(
                supportingCommand: "echo hi > file",
                workingDirectory: workspace,
                fingerprint: "shell:local-executor:redirect"
            )
        )
        let plan = try requireContainedPlan(workspace: workspace)
        expectCompileError(
            compileExecutable(allowed: allowed, plan: plan),
            .commandNotSimpleArgv,
            expected: "commandNotSimpleArgv"
        )
    }

    @Test func compileExecutable_fileAction_fails() throws {
        let workspace = try requireWorkspace("/tmp/rv")
        let action = ProposedAction.file(
            FileAction(
                fingerprint: ActionFingerprint(rawValue: "file:local-executor:write:/tmp/rv/new.swift"),
                file: FileToolAction(
                    kind: .write,
                    path: FileToolPath(rawValue: "/tmp/rv/new.swift")
                ),
                effects: ActionEffects(kinds: [.filesystemCreate]),
                resources: ActionResources(
                    path: "/tmp/rv/new.swift",
                    filesystemScope: .insideRepository,
                    resourceKind: .unknown
                ),
                scope: ActionScope(workingDirectory: workspace)
            )
        )
        let allowed = try requireAllowed(action, review: .success(qualifiedAllow))
        let plan = try requireContainedPlan(workspace: workspace)
        expectCompileError(
            compileExecutable(allowed: allowed, plan: plan),
            .fileActionUnsupported,
            expected: "fileActionUnsupported"
        )
    }

    @Test func compileExecutable_missingCommand_fails() throws {
        let workspace = try requireWorkspace("/tmp/rv")
        let allowed = try requireAllowed(
            inRepoWrite(
                supportingCommand: nil,
                workingDirectory: workspace,
                fingerprint: "shell:local-executor:missing-command"
            )
        )
        let plan = try requireContainedPlan(workspace: workspace)
        expectCompileError(
            compileExecutable(allowed: allowed, plan: plan),
            .missingCommand,
            expected: "missingCommand"
        )
    }

    @Test func compileExecutable_bareTouch_resolvesOnSafePath() throws {
        let workspace = try requireWorkspace("/tmp/rv")
        let allowed = try requireAllowed(
            inRepoWrite(
                supportingCommand: "touch ok.txt",
                workingDirectory: workspace,
                path: "/tmp/rv/ok.txt",
                fingerprint: "shell:local-executor:bare-touch"
            )
        )
        let plan = try requireContainedPlan(workspace: workspace)
        switch compileExecutable(allowed: allowed, plan: plan) {
        case .success(let executable):
            #expect(safeTouchExecutables.contains(executable.command.executable))
            #expect(executable.command.arguments == ["ok.txt"])
            #expect(executable.allowed == allowed)
            #expect(executable.plan == plan)
        case .failure(let error):
            recordUnexpectedCompileError(error, expected: "resolved bare touch")
        }
    }

    @Test func compileExecutable_unresolvedName_fails() throws {
        let workspace = try requireWorkspace("/tmp/rv")
        let allowed = try requireAllowed(
            inRepoWrite(
                supportingCommand: "definitely-not-a-bin-xxxx",
                workingDirectory: workspace,
                fingerprint: "shell:local-executor:unresolved"
            )
        )
        let plan = try requireContainedPlan(workspace: workspace)
        expectCompileError(
            compileExecutable(allowed: allowed, plan: plan),
            .executableNotResolved,
            expected: "executableNotResolved"
        )
    }

    @Test func compileExecutable_workspaceMismatch_fails() throws {
        let actionCwd = try requireWorkspace("/a")
        let planWorkspace = try requireWorkspace("/b")
        let allowed = try requireAllowed(
            inRepoWrite(
                supportingCommand: "touch ok.txt",
                workingDirectory: actionCwd,
                path: "/a/ok.txt",
                fingerprint: "shell:local-executor:workspace-mismatch"
            )
        )
        let plan = try requireContainedPlan(workspace: planWorkspace)
        expectCompileError(
            compileExecutable(allowed: allowed, plan: plan),
            .workspaceMismatch,
            expected: "workspaceMismatch"
        )
    }

    @Test func compileExecutable_missingWorkingDirectory_fails() throws {
        let workspace = try requireWorkspace("/tmp/rv")
        let allowedWithoutCwd = try requireAllowed(
            inRepoWrite(
                supportingCommand: "touch ok.txt",
                workingDirectory: nil,
                fingerprint: "shell:local-executor:missing-action-cwd"
            )
        )
        let contained = try requireContainedPlan(workspace: workspace)
        expectCompileError(
            compileExecutable(allowed: allowedWithoutCwd, plan: contained),
            .workingDirectoryRequired,
            expected: "workingDirectoryRequired for nil action cwd"
        )

        let allowedWithCwd = try requireAllowed(
            inRepoWrite(
                supportingCommand: "touch ok.txt",
                workingDirectory: workspace,
                fingerprint: "shell:local-executor:missing-plan-workspace"
            )
        )
        let observedWithoutWorkspace = try requireObservedPlan(workspace: nil)
        expectCompileError(
            compileExecutable(allowed: allowedWithCwd, plan: observedWithoutWorkspace),
            .workingDirectoryRequired,
            expected: "workingDirectoryRequired for nil plan workspace"
        )
    }

    @Test func compileExecutable_absoluteTouch_succeeds() throws {
        let workspace = try requireWorkspace("/tmp/rv")
        let touch = try requireTouchExecutable()
        let allowed = try requireAllowed(
            inRepoWrite(
                supportingCommand: "\(touch) ok.txt",
                workingDirectory: workspace,
                path: "/tmp/rv/ok.txt",
                fingerprint: "shell:local-executor:absolute-touch"
            )
        )
        let plan = try requireContainedPlan(workspace: workspace)
        switch compileExecutable(allowed: allowed, plan: plan) {
        case .success(let executable):
            #expect(executable.command.executable == touch)
            #expect(executable.command.arguments == ["ok.txt"])
            #expect(executable.allowed == allowed)
            #expect(executable.plan == plan)
        case .failure(let error):
            recordUnexpectedCompileError(error, expected: "absolute touch ExecutableAction")
        }
    }

    @Test func pendingAuthorization_hasNoExecuteInput() {
        let action = ProposedAction.shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:local-executor:pending"),
                effects: ActionEffects(),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: "echo hello")
            )
        )
        switch AgentAuthorization.decide(action: action) {
        case .pending:
            break
        case .allowed:
            Issue.record("uncovered echo must stay pending so it cannot enter run")
        case .denied:
            Issue.record("uncovered echo must stay pending, not denied")
        }
    }

    @Test func localExecutor_containedInWorkspaceWrite_succeeds() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("inside.txt").path
        let executable = try requireExecutable(
            supportingCommand: "\(try requireTouchExecutable()) \(inside)",
            workingDirectory: workspace,
            path: inside,
            fingerprint: "shell:local-executor:contained-in",
            plan: tree.contained
        )
        guard let result = try await runContainedOrRefuseOnLinux(executable, absentPath: inside) else {
            return
        }
        #expect(result.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: inside))
        expectContainedPlatform(result.established, matching: tree.contained)
    }

    @Test func localExecutor_containedOutsideWrite_deniedByKernel() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let outside = tree.siblingURL.appendingPathComponent("outside.txt").path
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        let executable = try requireExecutable(
            supportingCommand: "\(try requireTouchExecutable()) \(outside)",
            workingDirectory: workspace,
            path: outside,
            fingerprint: "shell:local-executor:contained-out",
            plan: tree.contained
        )
        guard let result = try await runContainedOrRefuseOnLinux(executable, absentPath: outside) else {
            return
        }
        #expect(result.exitStatus != 0)
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        expectContainedPlatform(result.established, matching: tree.contained)
    }

    @Test func localExecutor_observedPlan_applyFails() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.observed.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("observed.txt").path
        let executable = try requireExecutable(
            supportingCommand: "\(try requireTouchExecutable()) \(inside)",
            workingDirectory: workspace,
            path: inside,
            fingerprint: "shell:local-executor:observed",
            plan: tree.observed
        )
        do {
            let run = try await LocalExecutor().run(executable)
            switch run.established.mode {
            case .contained:
                Issue.record("observed plan must not establish contained")
            case .observed, .mediated:
                Issue.record("observed plan must throw applyFailed, not establish \(run.established.mode)")
            }
        } catch let error as LocalExecutorError {
            expectApplyFailedBackendUnavailable(error)
        } catch {
            Issue.record("observed plan must throw LocalExecutorError, got \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: inside) == false)
    }

    @Test func localExecutor_sameFingerprint_secondRunFails() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("once.txt").path
        let executable = try requireExecutable(
            supportingCommand: "\(try requireTouchExecutable()) \(inside)",
            workingDirectory: workspace,
            path: inside,
            fingerprint: "shell:local-executor:once",
            plan: tree.contained
        )
        let executor = LocalExecutor()
        #if os(Linux)
        do {
            _ = try await executor.run(executable)
            Issue.record("Linux first run must refuse the contained launch")
        } catch let error as LocalExecutorError {
            #expect(error == .applyFailed(.containedGuaranteesUnsupported))
        }
        #expect(FileManager.default.fileExists(atPath: inside) == false)
        do {
            _ = try await executor.run(executable)
            Issue.record("second run of the same fingerprint must throw alreadyExecuted")
        } catch let error as LocalExecutorError {
            switch error {
            case .alreadyExecuted(let fingerprint):
                #expect(fingerprint == executable.allowed.action.fingerprint)
            case .cancelled, .applyFailed:
                Issue.record("expected alreadyExecuted, got \(error)")
            }
        }
        return
        #endif
        let first = try await executor.run(executable)
        #expect(first.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: inside))
        do {
            _ = try await executor.run(executable)
            Issue.record("second run of the same fingerprint must throw alreadyExecuted")
        } catch let error as LocalExecutorError {
            switch error {
            case .alreadyExecuted(let fingerprint):
                #expect(fingerprint == executable.allowed.action.fingerprint)
            case .cancelled:
                Issue.record("expected alreadyExecuted, got cancelled")
            case .applyFailed(let apply):
                recordUnexpectedApplyError(apply, expected: "alreadyExecuted")
            }
        } catch {
            Issue.record("second run must throw LocalExecutorError, got \(error)")
        }
    }

    @Test func localExecutor_nonContainedRejection_allowsRetry() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("retry.txt").path
        let allowed = try requireAllowed(
            inRepoWrite(
                supportingCommand: "\(try requireTouchExecutable()) \(inside)",
                workingDirectory: workspace,
                path: inside,
                fingerprint: "shell:local-executor:retry"
            )
        )
        let observed = try requireExecutable(allowed, plan: tree.observed)
        let contained = try requireExecutable(allowed, plan: tree.contained)
        let executor = LocalExecutor()
        do {
            _ = try await executor.run(observed)
            Issue.record("observed first run must throw so the fingerprint stays free")
        } catch let error as LocalExecutorError {
            expectApplyFailedBackendUnavailable(error)
        } catch {
            Issue.record("observed first run must throw LocalExecutorError, got \(error)")
        }
        guard let result = try await runContainedOrRefuseOnLinux(contained, executor: executor, absentPath: inside)
        else {
            return
        }
        #expect(result.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: inside))
        expectContainedPlatform(result.established, matching: tree.contained)
    }

    @Test func localExecutor_askResolve_containedInWorkspaceTouch() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let workspace = try #require(tree.contained.workspace)
        let inside = tree.workspaceURL.appendingPathComponent("ask-resolve.txt").path
        let touch = try requireTouchExecutable()
        let action = ProposedAction.shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:local-executor:ask-resolve"),
                effects: ActionEffects(),
                scope: ActionScope(workingDirectory: workspace),
                supportingCommand: ShellCommand(rawValue: "\(touch) \(inside)")
            )
        )
        let pending = try requirePendingReviewAsk(action)
        let allowed = try requireResolvedAllowOnce(pending)
        let executable = try requireExecutable(allowed, plan: tree.contained)
        guard let result = try await runContainedOrRefuseOnLinux(executable, absentPath: inside) else {
            return
        }
        #expect(result.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: inside))
        expectContainedPlatform(result.established, matching: tree.contained)
    }
}

private func runContainedOrRefuseOnLinux(
    _ executable: ExecutableAction,
    executor: LocalExecutor = LocalExecutor(),
    absentPath: String
) async throws -> IsolatedRunResult? {
    do {
        let result = try await executor.run(executable)
        #if os(Linux)
        Issue.record("Linux contained launch must be refused, got exit \(result.exitStatus)")
        return nil
        #else
        return result
        #endif
    } catch let error as LocalExecutorError {
        #if os(Linux)
        #expect(error == .applyFailed(.containedGuaranteesUnsupported))
        #expect(FileManager.default.fileExists(atPath: absentPath) == false)
        return nil
        #else
        throw error
        #endif
    }
}

private let qualifiedAllow = ActionReview.make(
    decision: .allow,
    risk: .low,
    confidence: .high,
    rationale: "stub allow",
    rationaleCategory: .allow
)

private let safeTouchExecutables = ["/usr/bin/touch", "/bin/touch"]

private enum LocalExecutorFixtureError: Error {
    case expectedAllowed
    case expectedPending
    case missingTouch
    case compileFailed
}

private func inRepoWrite(
    supportingCommand: String?,
    workingDirectory: WorkingDirectory?,
    path: String = "/tmp/rv/file",
    fingerprint: String = "shell:local-executor:in-repo-write"
) -> ProposedAction {
    .shell(
        ShellAction(
            fingerprint: ActionFingerprint(rawValue: fingerprint),
            effects: ActionEffects(kinds: [.filesystemCreate]),
            resources: ActionResources(
                path: path,
                filesystemScope: .insideRepository,
                resourceKind: .unknown
            ),
            scope: ActionScope(workingDirectory: workingDirectory),
            supportingCommand: supportingCommand.map(ShellCommand.init(rawValue:))
        )
    )
}

private func requirePendingReviewAsk(_ action: ProposedAction) throws -> PendingAuthorization {
    switch AgentAuthorization.decide(action: action) {
    case .pending(let pending):
        #expect(pending.reason == .reviewAsk)
        return pending
    case .allowed:
        Issue.record("empty-effect uncovered must stay pending reviewAsk")
        throw LocalExecutorFixtureError.expectedPending
    case .denied(let denied):
        Issue.record("empty-effect uncovered must stay pending, got denied \(denied.deny.ruleID)")
        throw LocalExecutorFixtureError.expectedPending
    }
}

private func requireResolvedAllowOnce(_ pending: PendingAuthorization) throws -> AllowedAction {
    switch AgentAuthorization.resolve(pending, approval: .success(.allowOnce)) {
    case .success(.allowed(let allowed)):
        #expect(allowed.action == pending.action)
        #expect(allowed.action.fingerprint == pending.action.fingerprint)
        return allowed
    case .success(.denied):
        Issue.record("allowOnce on reviewAsk must produce AllowedAction")
        throw LocalExecutorFixtureError.expectedAllowed
    case .failure(let error):
        Issue.record("allowOnce on reviewAsk must not fail: \(error)")
        throw LocalExecutorFixtureError.expectedAllowed
    }
}

private func requireAllowed(
    _ action: ProposedAction,
    review: Result<ActionReview, ActionReviewerError> = .failure(.unsupported)
) throws -> AllowedAction {
    switch AgentAuthorization.decide(action: action, review: review) {
    case .allowed(let allowed):
        return allowed
    case .pending(let pending):
        Issue.record("expected allowed, got pending \(pending.reason)")
        throw LocalExecutorFixtureError.expectedAllowed
    case .denied(let denied):
        Issue.record("expected allowed, got denied \(denied.deny.ruleID)")
        throw LocalExecutorFixtureError.expectedAllowed
    }
}

private func requireWorkspace(_ path: String) throws -> WorkingDirectory {
    try #require(WorkingDirectory(validating: path))
}

private func requireContainedPlan(workspace: WorkingDirectory) throws -> IsolationPlan {
    try requirePlan(IsolationCompileRequest(requested: .contained, workspace: workspace))
}

private func requireObservedPlan(workspace: WorkingDirectory?) throws -> IsolationPlan {
    try requirePlan(IsolationCompileRequest(requested: .observed, workspace: workspace))
}

private func requirePlan(_ request: IsolationCompileRequest) throws -> IsolationPlan {
    switch compileIsolationPlan(request) {
    case .success(let plan):
        return plan
    case .failure(let error):
        switch error {
        case .containedRequiresWorkspace:
            Issue.record("fixture compile must not fail containedRequiresWorkspace")
            throw error
        }
    }
}

private func requireExecutable(
    supportingCommand: String,
    workingDirectory: WorkingDirectory,
    path: String,
    fingerprint: String,
    plan: IsolationPlan
) throws -> ExecutableAction {
    let allowed = try requireAllowed(
        inRepoWrite(
            supportingCommand: supportingCommand,
            workingDirectory: workingDirectory,
            path: path,
            fingerprint: fingerprint
        )
    )
    return try requireExecutable(allowed, plan: plan)
}

private func requireExecutable(
    _ allowed: AllowedAction,
    plan: IsolationPlan
) throws -> ExecutableAction {
    switch compileExecutable(allowed: allowed, plan: plan) {
    case .success(let executable):
        return executable
    case .failure(let error):
        recordUnexpectedCompileError(error, expected: "compiled ExecutableAction")
        throw LocalExecutorFixtureError.compileFailed
    }
}

private func requireTouchExecutable() throws -> String {
    for path in safeTouchExecutables {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    Issue.record("neither /usr/bin/touch nor /bin/touch exists")
    throw LocalExecutorFixtureError.missingTouch
}

private func expectCompileError(
    _ result: Result<ExecutableAction, ExecutableCompileError>,
    _ expected: ExecutableCompileError,
    expected expectedName: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success:
        Issue.record("\(expectedName) must not compile", sourceLocation: sourceLocation)
    case .failure(let error):
        if error == expected {
            return
        }
        recordUnexpectedCompileError(error, expected: expectedName, sourceLocation: sourceLocation)
    }
}

private func recordUnexpectedCompileError(
    _ error: ExecutableCompileError,
    expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch error {
    case .fileActionUnsupported:
        Issue.record("expected \(expected), got fileActionUnsupported", sourceLocation: sourceLocation)
    case .missingCommand:
        Issue.record("expected \(expected), got missingCommand", sourceLocation: sourceLocation)
    case .commandNotSimpleArgv:
        Issue.record("expected \(expected), got commandNotSimpleArgv", sourceLocation: sourceLocation)
    case .executableNotResolved:
        Issue.record("expected \(expected), got executableNotResolved", sourceLocation: sourceLocation)
    case .workingDirectoryRequired:
        Issue.record(
            "expected \(expected), got workingDirectoryRequired",
            sourceLocation: sourceLocation
        )
    case .workspaceMismatch:
        Issue.record("expected \(expected), got workspaceMismatch", sourceLocation: sourceLocation)
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

private func expectApplyFailedBackendUnavailable(
    _ error: LocalExecutorError,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch error {
    case .applyFailed(.backendUnavailable):
        break
    case .cancelled:
        Issue.record("expected applyFailed(backendUnavailable), got cancelled", sourceLocation: sourceLocation)
    case .alreadyExecuted(let fingerprint):
        Issue.record(
            "expected applyFailed(backendUnavailable), got alreadyExecuted \(fingerprint.rawValue)",
            sourceLocation: sourceLocation
        )
    case .applyFailed(let apply):
        recordUnexpectedApplyError(
            apply,
            expected: "applyFailed(backendUnavailable)",
            sourceLocation: sourceLocation
        )
    }
}

private func recordUnexpectedApplyError(
    _ error: IsolationApplyError,
    expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch error {
    case .commandContainsNUL:
        Issue.record("expected \(expected), got commandContainsNUL", sourceLocation: sourceLocation)
    case .backendUnavailable:
        Issue.record("expected \(expected), got backendUnavailable", sourceLocation: sourceLocation)
    case .backendMismatch:
        Issue.record("expected \(expected), got backendMismatch", sourceLocation: sourceLocation)
    case .workspaceMustBeAbsolute:
        Issue.record("expected \(expected), got workspaceMustBeAbsolute", sourceLocation: sourceLocation)
    case .workspaceDoesNotExist:
        Issue.record("expected \(expected), got workspaceDoesNotExist", sourceLocation: sourceLocation)
    case .workspacePathUnresolvable:
        Issue.record(
            "expected \(expected), got workspacePathUnresolvable",
            sourceLocation: sourceLocation
        )
    case .workspacePathUnsafe:
        Issue.record("expected \(expected), got workspacePathUnsafe", sourceLocation: sourceLocation)
    case .workspaceContainsInodeAlias:
        Issue.record("expected \(expected), got workspaceContainsInodeAlias", sourceLocation: sourceLocation)
    case .containedGuaranteesUnsupported:
        Issue.record(
            "expected \(expected), got containedGuaranteesUnsupported",
            sourceLocation: sourceLocation
        )
    case .profileNotApplicable:
        Issue.record("expected \(expected), got profileNotApplicable", sourceLocation: sourceLocation)
    case .processSpawnFailed:
        Issue.record("expected \(expected), got processSpawnFailed", sourceLocation: sourceLocation)
    case .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
        Issue.record(
            "expected \(expected), got commandExecutableMustBeAbsolute",
            sourceLocation: sourceLocation
        )
    }
}

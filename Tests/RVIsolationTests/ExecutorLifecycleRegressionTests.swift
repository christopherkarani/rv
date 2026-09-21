import Foundation
import RVDomain
import Testing
@testable import RVIsolation

@Suite("Executor lifecycle regressions")
struct ExecutorLifecycleRegressionTests {
    @Test func cancelledBeforeDispatch_doesNotExecuteOrConsumeAuthorization() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("cancelled-marker")
        let executable = try lifecycleExecutable(plan: tree.contained, marker: marker)
        let executor = LocalExecutor()

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await lifecycleRun(executor, executable)
        }
        let result = try await cancelled.value
        #expect(result == .failure(.cancelled))
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        guard case .failure = result else {
            Issue.record("a cancelled task must not dispatch an execution")
            return
        }

        let retry = try await executor.run(executable)
        #expect(retry.exitStatus == 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
    }

    @Test func failedApply_consumesAuthorizationBeforeRetry() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("retry-marker")
        let executable = try lifecycleExecutable(plan: tree.contained, marker: marker)
        let executor = LocalExecutor()

        try FileManager.default.removeItem(at: tree.workspaceURL)
        let first = try await lifecycleRun(executor, executable)
        #expect(first == .failure(.applyFailed(.workspaceDoesNotExist)))
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        try FileManager.default.createDirectory(at: tree.workspaceURL, withIntermediateDirectories: true)

        let second = try await lifecycleRun(executor, executable)
        #expect(second == .failure(.alreadyExecuted(executable.allowed.action.fingerprint)))
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test func reservedChildExit_cannotReplayCompletedSideEffect() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("reserved-exit-marker")
        let executable = try lifecycleExecutable(plan: tree.contained, marker: marker, exitStatus: 125)
        let executor = LocalExecutor()

        let first = try await lifecycleRun(executor, executable)
        #if os(Linux)
        #expect(first == .failure(.applyFailed(.backendUnavailable)))
        #else
        guard case .success(let result) = first else {
            Issue.record("the contained child must execute before its reserved exit")
            return
        }
        #expect(result.exitStatus == 125)
        #endif
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")

        let second = try await lifecycleRun(executor, executable)
        #expect(second == .failure(.alreadyExecuted(executable.allowed.action.fingerprint)))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
    }

    @Test func concurrentDispatch_sameAuthorizationExecutesOnlyOnce() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("concurrent-marker")
        let executable = try lifecycleExecutable(plan: tree.contained, marker: marker)
        let executor = LocalExecutor()

        async let first = lifecycleRun(executor, executable)
        async let second = lifecycleRun(executor, executable)
        let outcomes = try await [first, second]
        #expect(outcomes.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(outcomes.filter {
            $0 == .failure(.alreadyExecuted(executable.allowed.action.fingerprint))
        }.count == 1)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
    }
}

private enum ExecutorLifecycleFixtureError: Error {
    case expectedPending
    case expectedAllowed
}

/// Authorization is real; the internal executable initializer supplies shell argv
/// directly so these tests exercise dispatch rather than simple-command parsing.
private func lifecycleExecutable(
    plan: IsolationPlan,
    marker: URL,
    exitStatus: Int32 = 0
) throws -> ExecutableAction {
    let action = ProposedAction.shell(
        ShellAction(
            fingerprint: ActionFingerprint(rawValue: UUID().uuidString),
            scope: ActionScope(workingDirectory: plan.workspace)
        )
    )
    guard case .pending(let pending) = AgentAuthorization.decide(action: action) else {
        throw ExecutorLifecycleFixtureError.expectedPending
    }
    guard case .success(.allowed(let allowed)) = AgentAuthorization.resolve(
        pending, approval: .success(.allowOnce)
    ) else {
        throw ExecutorLifecycleFixtureError.expectedAllowed
    }
    let command = try #require(
        IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf x >> \"$1\"; exit \(exitStatus)", "sh", marker.path]
        )
    )
    return ExecutableAction(allowed: allowed, command: command, plan: plan)
}

private func lifecycleRun(
    _ executor: LocalExecutor,
    _ executable: ExecutableAction
) async throws -> Result<IsolatedRunResult, LocalExecutorError> {
    do {
        return .success(try await executor.run(executable))
    } catch let error as LocalExecutorError {
        return .failure(error)
    }
}

import Foundation
import RVDomain
import Testing
@testable import RVIsolation
#if canImport(Darwin)
import Darwin
#endif

@Suite("Executor lifecycle regressions")
struct ExecutorLifecycleRegressionTests {
    @Test func cancelledBeforeDispatch_doesNotExecuteOrConsumeAuthorization() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("cancelled-marker")
        let executable = try lifecycleExecutable(plan: try tree.containedPlan(), marker: marker)
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

        #if os(Linux)
        do {
            _ = try await executor.run(executable)
            Issue.record("Linux retry must refuse the contained launch")
        } catch let error as LocalExecutorError {
            #expect(error == .applyFailed(.containedGuaranteesUnsupported))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        return
        #endif
        let retry = try await executor.run(executable)
        #expect(retry.exitStatus == 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
    }

    @Test func failedApply_consumesAuthorizationBeforeRetry() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("retry-marker")
        let executable = try lifecycleExecutable(plan: try tree.containedPlan(), marker: marker)
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
        let executable = try lifecycleExecutable(plan: try tree.containedPlan(), marker: marker, exitStatus: 125)
        let executor = LocalExecutor()

        let first = try await lifecycleRun(executor, executable)
        #if os(Linux)
        #expect(first == .failure(.applyFailed(.containedGuaranteesUnsupported)))
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        let refusedSecond = try await lifecycleRun(executor, executable)
        #expect(refusedSecond == .failure(.alreadyExecuted(executable.allowed.action.fingerprint)))
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        return
        #endif
        guard case .success(let result) = first else {
            Issue.record("the contained child must execute before its reserved exit")
            return
        }
        #expect(result.exitStatus == 125)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")

        let second = try await lifecycleRun(executor, executable)
        #expect(second == .failure(.alreadyExecuted(executable.allowed.action.fingerprint)))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
    }

    @Test func concurrentDispatch_sameAuthorizationExecutesOnlyOnce() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("concurrent-marker")
        let executable = try lifecycleExecutable(plan: try tree.containedPlan(), marker: marker)
        let executor = LocalExecutor()

        async let first = lifecycleRun(executor, executable)
        async let second = lifecycleRun(executor, executable)
        let outcomes = try await [first, second]
        #if os(Linux)
        #expect(outcomes.filter { if case .success = $0 { true } else { false } }.count == 0)
        #expect(outcomes.filter {
            $0 == .failure(.alreadyExecuted(executable.allowed.action.fingerprint))
        }.count == 1)
        #expect(outcomes.filter {
            $0 == .failure(.applyFailed(.containedGuaranteesUnsupported))
        }.count == 1)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        return
        #endif
        #expect(outcomes.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(outcomes.filter {
            $0 == .failure(.alreadyExecuted(executable.allowed.action.fingerprint))
        }.count == 1)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
    }

    @Test func cancellationTerminatesOwnedProcessesBeforeReturn() async throws {
        #if os(macOS)
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let started = tree.workspaceURL.appendingPathComponent("started")
        let pidFile = tree.workspaceURL.appendingPathComponent("sleep.pid")
        let script = "printf started > \"$1\"; /bin/sleep 20 & printf '%s\\n' \"$!\" > \"$2.tmp\" && mv \"$2.tmp\" \"$2\"; wait"
        let executable = try lifecycleExecutable(
            plan: try tree.containedPlan(),
            marker: started,
            script: script,
            arguments: [started.path, pidFile.path]
        )
        let executor = LocalExecutor()
        let task = Task { try await lifecycleRun(executor, executable) }
        // DiskArbitration can queue hdiutil behind other suites. Wait until the
        // owned child exists, then cancel. The old failure was cancelling during
        // that wait: Process.waitUntilExit ignored the task, so this test hung
        // until the runner timed it out. A missing pid is still a failed launch,
        // but cancellation itself has to return.
        let deadline = Date().addingTimeInterval(90)
        var sleepPID: Int32?
        while Date() < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int32(trimmed), pid > 1, kill(pid, 0) == 0 {
                    sleepPID = pid
                    break
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        let cancelledAt = Date()
        let result = try await task.value
        #expect(Date().timeIntervalSince(cancelledAt) < 8)
        guard let pid = sleepPID else {
            Issue.record("contained sleep pid did not appear; launch returned \(result)")
            return
        }
        #expect(result == .failure(.cancelled))
        let probe = kill(pid, 0)
        let probeError = errno
        #expect(probe == -1)
        #expect(probeError == ESRCH)
        #endif
    }

    #if os(macOS)
    @Test func cancellingAHelperDoesNotWaitForItToExit() async throws {
        let task = Task { cancellableHelperProbe() }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let cancelledAt = Date()
        let status = await task.value
        #expect(Date().timeIntervalSince(cancelledAt) < 3)
        #expect(status < 0)
    }
    #endif
}

private enum ExecutorLifecycleFixtureError: Error {
    case expectedPending
    case expectedAllowed
}

/// Authorization is real; the internal executable initializer supplies shell argv
/// directly so these tests exercise dispatch rather than simple-command parsing.
private func lifecycleExecutable(
    plan: ContainedPlan,
    marker: URL,
    exitStatus: Int32 = 0,
    script: String? = nil,
    arguments: [String]? = nil
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
            arguments: arguments.map { ["-c", script ?? "", "sh"] + $0 }
                ?? ["-c", "printf x >> \"$1\"; exit \(exitStatus)", "sh", marker.path]
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

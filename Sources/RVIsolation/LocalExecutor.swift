import Foundation
import RVDomain
import Synchronization

public enum LocalExecutorError: Error, Sendable, Equatable {
    case cancelled
    case alreadyExecuted(ActionFingerprint)
    case applyFailed(IsolationApplyError)
}

/// Cancellation for blocking supervision that has left the cooperative pool.
///
/// `Task.isCancelled` is visible only on the task that owns the executor call.
/// The watch loop runs on a dedicated thread, so it reads this flag instead.
enum CooperativeLaunchStop {
    final class Flag: NSObject, Sendable {
        private let value = Mutex(false)

        func cancel() {
            value.withLock { $0 = true }
        }

        var isSet: Bool {
            value.withLock { $0 }
        }
    }

    private static let key = "rv.cooperativeLaunchStop"

    static func install(_ flag: Flag) {
        Thread.current.threadDictionary[key] = flag
    }

    static func uninstall() {
        Thread.current.threadDictionary.removeObject(forKey: key)
    }

    static var isRequested: Bool {
        (Thread.current.threadDictionary[key] as? Flag)?.isSet ?? false
    }
}

private final class ExecutorApplyGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 1)

    func wait() {
        semaphore.wait()
    }

    func signal() {
        semaphore.signal()
    }
}

/// Dispatches a compiled `ExecutableAction` at most once per fingerprint.
///
/// Spawn is only `IsolationBackends.apply`. The contained plan is converted
/// to `IsolationPlan` at that call.
public actor LocalExecutor {
    private var dispatched: Set<ActionFingerprint> = []
    private let applyGate = ExecutorApplyGate()

    public init() {}

    public func run(_ executable: ExecutableAction) async throws -> IsolatedRunResult {
        guard Task.isCancelled == false else {
            throw LocalExecutorError.cancelled
        }
        let fingerprint = executable.allowed.action.fingerprint
        if dispatched.contains(fingerprint) {
            throw LocalExecutorError.alreadyExecuted(fingerprint)
        }
        // Apply can fail after the child has produced effects. Never make the
        // same authorization reusable based on an ambiguous backend result.
        dispatched.insert(fingerprint)
        let plan = executable.plan.isolationPlan()
        let command = executable.command
        let gate = applyGate
        let flag = CooperativeLaunchStop.Flag()
        // `usleep` and disk-image setup block. Doing that on a cooperative
        // thread stalls every other test task, so cancellation never runs and
        // the suite times out. This thread is the one the watch loop polls.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    gate.wait()
                    defer { gate.signal() }
                    if flag.isSet {
                        continuation.resume(throwing: LocalExecutorError.cancelled)
                        return
                    }
                    CooperativeLaunchStop.install(flag)
                    IsolationBlockingWork.markOffPool()
                    defer {
                        IsolationBlockingWork.clearOffPool()
                        CooperativeLaunchStop.uninstall()
                    }
                    switch IsolationBackends.apply(plan, command: command) {
                    case .success(let result):
                        continuation.resume(returning: result)
                    case .failure(.cancelled):
                        continuation.resume(throwing: LocalExecutorError.cancelled)
                    case .failure(let error):
                        continuation.resume(throwing: LocalExecutorError.applyFailed(error))
                    }
                }
                thread.name = "rv-executor-apply"
                thread.start()
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Dispatches an already-decided authorization. Does not call `decide`.
    ///
    /// Allowed compiles and runs. Denied returns without spawn. Pending
    /// without approval waits. Pending with approval goes through `step`,
    /// which maps the ledger click through `humanDecision` before `resolve`.
    public func perform(
        _ authorization: AgentAuthorization,
        plan: ContainedPlan,
        approval: Result<ApprovalDecision, AgentApprovalError>? = nil
    ) async -> Result<AgentTurn, AgentTurnError> {
        switch AgentAuthorization.step(authorization, approval: approval) {
        case .execute(let allowed):
            return await compileAndRun(allowed: allowed, plan: plan)
        case .denied(let denied):
            return .success(.denied(denied))
        case .awaitingApproval(let pending):
            return .success(.awaitingApproval(pending))
        case .approvalFailed(let error):
            return .failure(.approval(error))
        }
    }

    private func compileAndRun(
        allowed: AllowedAction,
        plan: ContainedPlan
    ) async -> Result<AgentTurn, AgentTurnError> {
        switch compileExecutable(allowed: allowed, plan: plan) {
        case .failure(let error):
            return .failure(.compile(error))
        case .success(let executable):
            do {
                return .success(.executed(try await run(executable)))
            } catch let error as LocalExecutorError {
                return .failure(.execute(error))
            } catch {
                preconditionFailure("LocalExecutor.run throws only LocalExecutorError")
            }
        }
    }
}

/// True when the current task is cancelled, or this thread is the executor
/// worker whose task was cancelled after `run` hopped off the cooperative pool.
/// `Task.isCancelled` does not cross that hop.
func blockingWorkIsCancelled() -> Bool {
    Task.isCancelled || CooperativeLaunchStop.isRequested
}

/// Runs blocking isolation work on a Foundation thread.
///
/// A synchronous wait on the cooperative pool pins that thread, so Swift
/// Testing cannot report a suite result. Callers `await` this hop. A thread
/// that is already off the pool runs `body` inline, so a nested call does
/// not start a second thread. Cancellation is the pthread flag the watch
/// loop already polls; `Task.isCancelled` does not cross the hop.
enum IsolationBlockingWork {
    private static let key = "rv.blockingWorkOffPool"

    static func markOffPool() {
        Thread.current.threadDictionary[key] = true
    }

    static func clearOffPool() {
        Thread.current.threadDictionary.removeObject(forKey: key)
    }

    static var isOffPool: Bool {
        (Thread.current.threadDictionary[key] as? Bool) == true
    }

    static func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        if isOffPool {
            return body()
        }
        let flag = CooperativeLaunchStop.Flag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                let thread = Thread {
                    IsolationBlockingWork.markOffPool()
                    CooperativeLaunchStop.install(flag)
                    defer {
                        CooperativeLaunchStop.uninstall()
                        IsolationBlockingWork.clearOffPool()
                    }
                    continuation.resume(returning: body())
                }
                thread.name = "rv-blocking-work"
                thread.start()
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

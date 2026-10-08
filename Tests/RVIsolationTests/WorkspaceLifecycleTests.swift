#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

#if os(macOS)
/// Lifecycle decisions through the supervisor, the one surviving decider.
///
/// These tests drive `WorkspaceSessionSupervisor`'s real close/recovery
/// behavior: open reaches active, concurrent closes elect one leader,
/// finished closes replay without new work, and only a close that stopped
/// with children alive stays retryable. No test here names a shadow state
/// machine; the supervisor owns the lock discipline and the threads.
@Suite("Workspace lifecycle", .serialized)
struct WorkspaceLifecycleTests {
    @Test func openReachesActiveAndClosePublishesOnce() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openLifecycleWorkspace(tree)
        let supervisor = opened.supervisor
        #expect(supervisor.snapshot.phase == .active)
        #expect(lifecycleSucceeded(supervisor.close()))
        #expect(supervisor.snapshot.phase == .closed)
        #expect(supervisor.publishCount == 1)
        #expect(closedRecordCount(in: opened.lifeLog) == 1)
    }

    @Test func concurrentClosesElectOneLeader() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openLifecycleWorkspace(tree)
        let supervisor = opened.supervisor
        let running = try launchLifecycleRuntime(
            supervisor,
            log: opened.runtimeLog,
            script: "printf held > held.txt; /bin/sleep 30"
        )
        #expect(waitForLifecycle(tree.workspaceURL.appendingPathComponent("held.txt")))
        let pid = try #require(running.session.child?.pid)
        let box = LifecycleCloseBox()
        let rival = Thread {
            box.result = supervisor.close()
        }
        rival.start()
        let first = supervisor.close()
        let join = Date().addingTimeInterval(90)
        while rival.isExecuting, Date() < join {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(rival.isExecuting == false)
        // One close leads teardown; the other joins it. Both observe the
        // same success and the workspace publishes exactly once.
        #expect(lifecycleSucceeded(first))
        #expect(lifecycleSucceeded(box.result))
        #expect(supervisor.snapshot.phase == .closed)
        #expect(supervisor.publishCount == 1)
        #expect(lifecycleProcessGone(pid))
        #expect(closedRecordCount(in: opened.lifeLog) == 1)
    }

    @Test func closeAfterCloseReplaysWithoutNewWork() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openLifecycleWorkspace(tree)
        let supervisor = opened.supervisor
        #expect(lifecycleSucceeded(supervisor.close()))
        // Terminal: the finished close replays; nothing publishes again and
        // no second `closed` record is appended.
        #expect(lifecycleSucceeded(supervisor.close()))
        #expect(supervisor.publishCount == 1)
        #expect(closedRecordCount(in: opened.lifeLog) == 1)
    }

    @Test func abandonedCloseAnswersAlreadyClosed() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openLifecycleWorkspace(tree)
        let supervisor = opened.supervisor
        supervisor.abandonForCrashSimulation()
        // Terminal: every close after abandon answers; none hangs or leads.
        guard case .failure(.alreadyClosed) = supervisor.close() else {
            Issue.record("close after abandon must answer alreadyClosed")
            return
        }
        guard case .failure(.alreadyClosed) = supervisor.close() else {
            Issue.record("second close after abandon must answer alreadyClosed")
            return
        }
        #expect(supervisor.publishCount == 0)
    }

    @Test func closeFailureCachesOnlyTerminalFailures() {
        // The leader's retryable-vs-terminal decision: only a close that
        // stopped with children alive releases leadership so a later close
        // can publish. Every other failure replays without new work.
        #expect(WorkspaceSessionSupervisor.closeFailureIsTerminal(.childTeardownFailed) == false)
        let terminal: [WorkspaceSessionError] = [
            .apply(.workspaceInodeBoundaryFailed),
            .notAcceptingRuntime(.closing),
            .cleanupFailed(.workspaceInodeBoundaryFailed),
            .alreadyClosed,
            .unknownRuntime(RuntimeSessionID()),
            .runtimeLimit,
            .ownedByLiveProcess(nil),
            .recoveryInProgress(UUID()),
            .unresolvedWorkspace(WorkspaceRecoveryBlock(workspace: nil, reason: .tornLog)),
            .preparationFailed(.workspaceNotActive),
            .unknownPreparedLaunch,
            .redemptionAlreadyAccepted,
        ]
        for error in terminal {
            #expect(
                WorkspaceSessionSupervisor.closeFailureIsTerminal(error),
                "\(error) must be terminal"
            )
        }
    }

    @Test func cancelUnknownRuntimeAnswersWithoutWork() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openLifecycleWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let unknown = RuntimeSessionID()
        guard case .failure(.unknownRuntime(let answered)) = opened.supervisor.cancel(unknown) else {
            Issue.record("cancel of an unknown runtime must be refused")
            return
        }
        #expect(answered == unknown)
    }

    @Test func launchAfterCloseIsRefused() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openLifecycleWorkspace(tree)
        let supervisor = opened.supervisor
        #expect(lifecycleSucceeded(supervisor.close()))
        let startsBefore = RuntimeSessionLog.records(at: opened.runtimeLog).count
        let marker = tree.workspaceURL.appendingPathComponent("refused")
        let refused = supervisor.launch(
            host: .opencode,
            command: try lifecycleShell("printf no > refused"),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(opened.runtimeLog)
        )
        guard case .failure(.notAcceptingRuntime(let phase)) = refused else {
            Issue.record("launch after close must be refused, got \(refused)")
            return
        }
        #expect(phase == .closed)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #expect(RuntimeSessionLog.records(at: opened.runtimeLog).count == startsBefore)
    }
}

private struct LifecycleOpened {
    var supervisor: WorkspaceSessionSupervisor
    var runtimeLog: URL
    var lifeLog: URL
}

private func openLifecycleWorkspace(_ tree: ContainmentTree) throws -> LifecycleOpened {
    let runtimeLog = tree.rootURL.appendingPathComponent("runtime-\(UUID().uuidString).jsonl")
    let lifeLog = tree.rootURL.appendingPathComponent("workspace-\(UUID().uuidString).jsonl")
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory,
        lifecycleLog: .file(lifeLog)
    ).get()
    return LifecycleOpened(supervisor: supervisor, runtimeLog: runtimeLog, lifeLog: lifeLog)
}

private func launchLifecycleRuntime(
    _ supervisor: WorkspaceSessionSupervisor,
    log: URL,
    script: String
) throws -> RunningRuntime {
    try supervisor.launch(
        host: .opencode,
        command: lifecycleShell(script),
        plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
        io: .discard,
        admission: .failClosed,
        sessionStore: .file(log)
    ).get()
}

private func lifecycleShell(_ script: String) throws -> IsolatedCommand {
    try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script]))
}

private func closedRecordCount(in lifeLog: URL) -> Int {
    WorkspaceLifecycleLog.records(at: lifeLog).count { $0.kind == .closed }
}

private func waitForLifecycle(_ url: URL) -> Bool {
    waitUntilLifecycle(seconds: 20) { FileManager.default.fileExists(atPath: url.path) }
}

private func waitUntilLifecycle(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

private func lifecycleSucceeded(_ result: Result<Void, WorkspaceSessionError>?) -> Bool {
    guard let result else { return false }
    if case .success = result { return true }
    return false
}

private func lifecycleProcessGone(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 { return false }
    return errno == ESRCH
}

private final class LifecycleCloseBox: Sendable {
    private let box = Mutex<Result<Void, WorkspaceSessionError>?>(nil)

    var result: Result<Void, WorkspaceSessionError>? {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}
#endif

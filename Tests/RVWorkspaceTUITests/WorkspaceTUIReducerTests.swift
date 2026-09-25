import Foundation
import Testing
@testable import RVWorkspaceTUI

private let shellChoice = RuntimeLaunchChoice(
    id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil
)
private let opencodeChoice = RuntimeLaunchChoice(
    id: "opencode", title: "opencode", executable: "/bin/opencode", arguments: [], hook: "opencode"
)
private let testSummary = WorkspaceTUISummary(
    project: "/tmp/project",
    phase: "active",
    protected: true,
    workspace: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
)
private let runtimeA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let runtimeB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

private func initialState(launcher: [RuntimeLaunchChoice] = [shellChoice, opencodeChoice]) -> WorkspaceTUIState {
    WorkspaceTUIState(
        lifecycle: .neverConnected,
        summary: testSummary,
        launcher: launcher,
        initialRows: 24,
        initialColumns: 80,
        mode: .terminal,
        terminal: nil,
        leasedRuntime: nil,
        retryAcquire: false,
        shouldExit: false,
        initialLaunchRequested: false,
        viewSize: nil,
        presentationRevision: 0
    )
}

private func attachedTerminal(
    runtime: UUID = runtimeA,
    title: String = "shell",
    running: Bool = true,
    exitStatus: Int32? = nil,
    lease: InputLease = .owned,
    subscribed: Bool = true,
    overflowed: Bool = false
) -> WorkspaceTUIState.AttachedTerminal {
    var resize = ResizeCoalescer()
    resize.recordLaunch(rows: 24, columns: 80)
    return WorkspaceTUIState.AttachedTerminal(
        state: WorkspaceTerminalState(
            runtime: runtime,
            title: title,
            running: running,
            exitStatus: exitStatus,
            lease: lease,
            subscribed: subscribed,
            overflowed: overflowed
        ),
        resize: resize
    )
}

private func connectedState(
    terminal: WorkspaceTUIState.AttachedTerminal? = attachedTerminal(),
    leasedRuntime: UUID? = runtimeA,
    mode: CommandMode = .terminal,
    retryAcquire: Bool = false
) -> WorkspaceTUIState {
    var state = initialState()
    state.lifecycle = .connected
    state.terminal = terminal
    state.leasedRuntime = leasedRuntime
    state.mode = mode
    state.retryAcquire = retryAcquire
    state.presentationRevision = 1
    return state
}

@Suite struct WorkspaceTUIReducerTests {
    @Test func connectRequestsQueryFromInitialState() {
        let before = initialState()
        let transition = WorkspaceTUIReducer.reduce(before, .connectRequested)
        #expect(transition.effects == [.queryConnect])
        #expect(transition.state == before)
    }

    @Test func connectIsIdempotentOnceDecided() {
        for lifecycle: WorkspaceTUILifecycle in [.connected, .disconnected, .detached] {
            var before = initialState()
            before.lifecycle = lifecycle
            let transition = WorkspaceTUIReducer.reduce(before, .connectRequested)
            #expect(transition.effects == [])
            #expect(transition.state == before)
        }
    }

    @Test func connectAttachesFirstTerminalRuntimeSorted() {
        let before = initialState()
        let runtimes = [
            ListedRuntime(id: runtimeB, hook: "opencode", running: true, terminal: true),
            ListedRuntime(id: runtimeA, hook: nil, running: true, terminal: true),
            ListedRuntime(id: UUID(), hook: nil, running: true, terminal: false),
        ]
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .connectQuery(described: testSummary, runtimes: runtimes)
        )
        #expect(transition.state.lifecycle == .connected)
        #expect(transition.state.terminal?.state.runtime == runtimeA)
        #expect(transition.state.terminal?.state.title == "runtime")
        #expect(transition.effects == [
            .createEmulator(runtime: runtimeA, rows: 24, columns: 80),
            .subscribe(runtime: runtimeA, context: .connect),
        ])
        #expect(transition.state.presentationRevision == 1)
    }

    @Test func connectWithNoTerminalRuntimeAttachesNothing() {
        let before = initialState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .connectQuery(described: testSummary, runtimes: [])
        )
        #expect(transition.state.lifecycle == .connected)
        #expect(transition.state.terminal == nil)
        #expect(transition.effects == [])
    }

    @Test func connectQueryFailedStaysRetryable() {
        let before = initialState()
        let failed = WorkspaceTUIReducer.reduce(before, .connectQueryFailed)
        #expect(failed.state.lifecycle == .neverConnected)
        #expect(failed.effects == [])
        let retry = WorkspaceTUIReducer.reduce(failed.state, .connectRequested)
        #expect(retry.effects == [.queryConnect])
    }

    @Test func launchDefaultRequestsEnsureOnce() {
        var before = connectedState(terminal: nil, leasedRuntime: nil)
        let first = WorkspaceTUIReducer.reduce(before, .launchDefaultRequested)
        #expect(first.effects == [.ensureShell(choice: shellChoice, rows: 24, columns: 80)])
        #expect(first.state.initialLaunchRequested)
        before = first.state
        let second = WorkspaceTUIReducer.reduce(before, .launchDefaultRequested)
        #expect(second.effects == [])
        #expect(second.state == before)
    }

    @Test func launchDefaultFallsBackToLauncherWithoutShell() {
        var before = initialState(launcher: [opencodeChoice])
        before.lifecycle = .connected
        let transition = WorkspaceTUIReducer.reduce(before, .launchDefaultRequested)
        #expect(transition.effects == [])
        #expect(transition.state.mode == .launcher)
        #expect(transition.state.initialLaunchRequested)
        #expect(transition.state.presentationRevision == 1)
    }

    @Test func launchDefaultIsBlockedWhenAttached() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .launchDefaultRequested)
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func ensureSuccessTitlesHookedRuntimeFromLauncher() {
        let before = connectedState(terminal: nil, leasedRuntime: nil)
        let runtime = ListedRuntime(id: runtimeA, hook: "opencode", running: true, terminal: true)
        let transition = WorkspaceTUIReducer.reduce(before, .ensureSucceeded(runtime: runtime, shell: shellChoice))
        #expect(transition.state.terminal?.state.title == "opencode")
        #expect(transition.effects == [
            .createEmulator(runtime: runtimeA, rows: 24, columns: 80),
            .subscribe(runtime: runtimeA, context: .ensure),
        ])
    }

    @Test func ensureSuccessTitlesUnhookedRuntime() {
        let before = connectedState(terminal: nil, leasedRuntime: nil)
        let created = ListedRuntime(id: runtimeA, hook: nil, running: true, terminal: true, created: true)
        #expect(
            WorkspaceTUIReducer.reduce(before, .ensureSucceeded(runtime: created, shell: shellChoice))
                .state.terminal?.state.title == "shell"
        )
        let reused = ListedRuntime(id: runtimeA, hook: nil, running: true, terminal: true, created: false)
        #expect(
            WorkspaceTUIReducer.reduce(before, .ensureSucceeded(runtime: reused, shell: shellChoice))
                .state.terminal?.state.title == "runtime"
        )
    }

    @Test func ensureFailedShowsLauncherOrDisconnects() {
        let before = connectedState(terminal: nil, leasedRuntime: nil)
        let rejected = WorkspaceTUIReducer.reduce(before, .ensureFailed(disconnected: false))
        #expect(rejected.state.mode == .launcher)
        #expect(rejected.state.lifecycle == .connected)
        let dropped = WorkspaceTUIReducer.reduce(before, .ensureFailed(disconnected: true))
        #expect(dropped.state.lifecycle == .disconnected)
    }

    @Test func keySendQueuesTerminalWrite() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .key(.character("a")))
        #expect(transition.effects == [.queueSend(runtime: runtimeA, bytes: Data("a".utf8))])
        #expect(transition.state.mode == .terminal)
        #expect(transition.state.presentationRevision == before.presentationRevision)
    }

    @Test func keyDetachSetsShouldExitWithoutEffects() {
        let before = connectedState()
        let prefixed = WorkspaceTUIReducer.reduce(before, .key(.control("g")))
        #expect(prefixed.state.mode == .prefix)
        #expect(prefixed.effects == [])
        let detached = WorkspaceTUIReducer.reduce(prefixed.state, .key(.character("d")))
        #expect(detached.state.shouldExit)
        #expect(detached.state.mode == .terminal)
        #expect(detached.effects == [])
        let ignored = WorkspaceTUIReducer.reduce(detached.state, .key(.character("a")))
        #expect(ignored.effects == [])
        #expect(ignored.state == detached.state)
    }

    @Test func keyNumberLaunchesDirectlyFromEmptyWorkspace() {
        let before = connectedState(terminal: nil, leasedRuntime: nil)
        let transition = WorkspaceTUIReducer.reduce(before, .key(.character("2")))
        #expect(transition.effects == [.queueLaunch(choice: opencodeChoice)])
    }

    @Test func keyIsIgnoredOnceDetached() {
        var before = connectedState()
        before.lifecycle = .detached
        let transition = WorkspaceTUIReducer.reduce(before, .key(.character("a")))
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func keyHelpEntersHelpModeWithoutEffects() {
        let before = connectedState(mode: .prefix)
        let transition = WorkspaceTUIReducer.reduce(before, .key(.character("?")))
        #expect(transition.state.mode == .help)
        #expect(transition.state.shouldExit == false)
        #expect(transition.effects == [])
        #expect(transition.state.presentationRevision == before.presentationRevision + 1)
    }

    @Test func keyDismissesOverlaysWithoutEffects() {
        let fromHelp = WorkspaceTUIReducer.reduce(connectedState(mode: .help), .key(.character("a")))
        #expect(fromHelp.state.mode == .terminal)
        #expect(fromHelp.effects == [])

        let fromLauncher = WorkspaceTUIReducer.reduce(connectedState(mode: .launcher), .key(.escape))
        #expect(fromLauncher.state.mode == .terminal)
        #expect(fromLauncher.effects == [])
    }

    @Test func keyNilDecisionsChangeOnlyTheMode() {
        let before = connectedState()
        let entered = WorkspaceTUIReducer.reduce(before, .key(.control("g")))
        #expect(entered.state.mode == .prefix)
        #expect(entered.effects == [])
        #expect(entered.state.presentationRevision == before.presentationRevision + 1)

        let cancelled = WorkspaceTUIReducer.reduce(entered.state, .key(.character("q")))
        #expect(cancelled.state.mode == .terminal)
        #expect(cancelled.effects == [])

        let launcher = WorkspaceTUIReducer.reduce(connectedState(mode: .launcher), .key(.character("x")))
        #expect(launcher.state.mode == .terminal)
        #expect(launcher.effects == [])
    }

    @Test func sendDueRequiresTheOwnedLease() {
        let before = connectedState()
        #expect(
            WorkspaceTUIReducer.reduce(before, .sendDue(runtime: runtimeA, bytes: Data("a".utf8))).effects
                == [.write(runtime: runtimeA, bytes: Data("a".utf8))]
        )
        #expect(
            WorkspaceTUIReducer.reduce(before, .sendDue(runtime: runtimeB, bytes: Data("a".utf8))).effects == []
        )
        var readOnly = before
        readOnly.leasedRuntime = nil
        readOnly.terminal?.state.lease = .readOnly
        #expect(
            WorkspaceTUIReducer.reduce(readOnly, .sendDue(runtime: runtimeA, bytes: Data("a".utf8))).effects == []
        )
    }

    @Test func launchDueUsesTheLatestViewSize() {
        var before = connectedState(terminal: nil, leasedRuntime: nil)
        before.viewSize = .init(rows: 30, columns: 90)
        let transition = WorkspaceTUIReducer.reduce(before, .launchDue(choice: shellChoice))
        #expect(transition.effects == [.launchQuery(choice: shellChoice, rows: 30, columns: 90)])
        let running = connectedState()
        #expect(WorkspaceTUIReducer.reduce(running, .launchDue(choice: shellChoice)).effects == [])
    }

    @Test func launchSucceededAttachesAndRotatesSubscription() {
        let exited = attachedTerminal(running: false, exitStatus: 0, lease: .released, subscribed: true)
        let before = connectedState(terminal: exited, leasedRuntime: nil, mode: .launcher)
        let runtime = ListedRuntime(id: runtimeB, hook: nil, running: true, terminal: true, created: true)
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .launchQuerySucceeded(choice: opencodeChoice, runtime: runtime, rows: 24, columns: 80)
        )
        #expect(transition.state.terminal?.state.runtime == runtimeB)
        #expect(transition.state.terminal?.state.title == "opencode")
        #expect(transition.state.mode == .terminal)
        #expect(transition.effects == [
            .createEmulator(runtime: runtimeB, rows: 24, columns: 80),
            .unsubscribe(runtime: runtimeA),
            .subscribe(runtime: runtimeB, context: .launch),
        ])
    }

    @Test func launchSucceededWhileRunningCancelsTheNewRuntime() {
        let before = connectedState()
        let runtime = ListedRuntime(id: runtimeB, hook: nil, running: true, terminal: true, created: true)
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .launchQuerySucceeded(choice: shellChoice, runtime: runtime, rows: 24, columns: 80)
        )
        #expect(transition.state == before)
        #expect(transition.effects == [.cancel(runtime: runtimeB)])
    }

    @Test func launchRacingDetachKeepsTheRuntimeAlive() {
        var before = connectedState()
        before.lifecycle = .detached
        before.shouldExit = true
        let runtime = ListedRuntime(id: runtimeB, hook: nil, running: true, terminal: true, created: true)
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .launchQuerySucceeded(choice: shellChoice, runtime: runtime, rows: 24, columns: 80)
        )
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func launchFailedShowsLauncher() {
        let before = connectedState(mode: .terminal)
        let transition = WorkspaceTUIReducer.reduce(before, .launchQueryFailed)
        #expect(transition.state.mode == .launcher)
        #expect(transition.effects == [])
    }

    @Test func eventsForUnattachedRuntimesAreIgnored() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .hostEvents([
            .bytes(runtime: runtimeB, data: Data("elsewhere".utf8)),
            .overflow(runtime: runtimeB),
            .exited(runtime: runtimeB, status: 3),
            .inputOwner(runtime: runtimeB, owned: false),
        ]))
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func bytesFeedTheEmulatorAndBumpTheRevision() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .hostEvents([.bytes(runtime: runtimeA, data: Data("hi".utf8))])
        )
        #expect(transition.effects == [.feedEmulator(runtime: runtimeA, data: Data("hi".utf8))])
        #expect(transition.state.presentationRevision == before.presentationRevision + 1)
        let empty = WorkspaceTUIReducer.reduce(before, .hostEvents([.bytes(runtime: runtimeA, data: Data())]))
        #expect(empty.effects == [])
        #expect(empty.state == before)
    }

    @Test func delayedReleaseDoesNotRevokeANewerAcquire() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .hostEvents([
            .inputOwner(runtime: runtimeA, owned: false),
            .inputOwner(runtime: runtimeA, owned: true),
        ]))
        #expect(transition.state == before)
    }

    @Test func releaseWithoutLeaseGoesReadOnlyAndRetries() {
        var before = connectedState(leasedRuntime: nil)
        before.terminal?.state.lease = .owned
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .hostEvents([.inputOwner(runtime: runtimeA, owned: false)])
        )
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.retryAcquire)
    }

    @Test func ownedBroadcastNeverGrantsTheLease() {
        var before = connectedState(leasedRuntime: nil)
        before.terminal?.state.lease = .released
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .hostEvents([.inputOwner(runtime: runtimeA, owned: true)])
        )
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.leasedRuntime == nil)
    }

    @Test func exitedTerminalOffersTheLauncher() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .hostEvents([.exited(runtime: runtimeA, status: 0)])
        )
        #expect(transition.state.terminal?.state.running == false)
        #expect(transition.state.terminal?.state.exitStatus == 0)
        #expect(transition.state.terminal?.state.lease == .released)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.state.mode == .launcher)
        #expect(transition.state.terminal?.state.runtime == runtimeA)
    }

    @Test func emulatorRepliesRequireTheOwnedLease() {
        let before = connectedState()
        let owned = WorkspaceTUIReducer.reduce(
            before,
            .emulatorResponded(runtime: runtimeA, responses: [Data("R".utf8)])
        )
        #expect(owned.effects == [.queueSend(runtime: runtimeA, bytes: Data("R".utf8))])
        var readOnly = before
        readOnly.terminal?.state.lease = .readOnly
        readOnly.leasedRuntime = nil
        let dropped = WorkspaceTUIReducer.reduce(
            readOnly,
            .emulatorResponded(runtime: runtimeA, responses: [Data("R".utf8)])
        )
        #expect(dropped.effects == [])
        #expect(dropped.state == readOnly)
    }

    @Test func sizeNotedRecordsGeometryWithoutEffects() {
        let before = connectedState()
        let now = Date(timeIntervalSince1970: 10_000)
        let transition = WorkspaceTUIReducer.reduce(before, .sizeNoted(rows: 30, columns: 90, now: now))
        #expect(transition.effects == [])
        #expect(transition.state.viewSize == .init(rows: 30, columns: 90))
        #expect(transition.state.presentationRevision == before.presentationRevision)
    }

    @Test func tickEmitsOnlyAStableResizeChange() {
        var before = connectedState()
        let idle = WorkspaceTUIReducer.reduce(before, .tick(now: Date()))
        #expect(idle.effects == [])
        #expect(idle.state.retryAcquire == false)

        let noted = WorkspaceTUIReducer.reduce(before, .sizeNoted(rows: 30, columns: 90, now: Date()))
        before = noted.state
        let settled = WorkspaceTUIReducer.reduce(before, .tick(now: Date().addingTimeInterval(60)))
        #expect(settled.effects == [
            .resizeEmulator(runtime: runtimeA, rows: 30, columns: 90),
            .resize(runtime: runtimeA, rows: 30, columns: 90),
        ])
        #expect(settled.state.presentationRevision == before.presentationRevision + 1)
    }

    @Test func tickRetriesTheLeaseOnce() {
        var before = connectedState(leasedRuntime: nil, retryAcquire: true)
        before.terminal?.state.lease = .readOnly
        let transition = WorkspaceTUIReducer.reduce(before, .tick(now: Date()))
        #expect(transition.effects == [.acquire(runtime: runtimeA)])
        #expect(transition.state.retryAcquire == false)
    }

    @Test func writeBusyDowngradesTheLease() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .writeCompleted(runtime: runtimeA, outcome: .busy))
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.state.presentationRevision == before.presentationRevision + 1)
    }

    @Test func writeOutcomesAreScopedToTheAttachedRuntime() {
        let before = connectedState()
        let other = WorkspaceTUIReducer.reduce(before, .writeCompleted(runtime: runtimeB, outcome: .busy))
        #expect(other.effects == [])
        #expect(other.state == before)
        let ok = WorkspaceTUIReducer.reduce(before, .writeCompleted(runtime: runtimeA, outcome: .ok))
        #expect(ok.effects == [])
        #expect(ok.state == before)
    }

    @Test func writeDisconnectedMarksTheWorkspaceReadOnly() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .writeCompleted(runtime: runtimeA, outcome: .disconnected))
        #expect(transition.state.lifecycle == .disconnected)
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.terminal?.state.subscribed == false)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.state.retryAcquire == false)
        #expect(transition.state.presentationRevision == before.presentationRevision + 1)
        #expect(transition.effects == [])
    }

    @Test func acquireDisconnectedMarksTheWorkspaceReadOnly() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .acquireCompleted(runtime: runtimeA, outcome: .disconnected)
        )
        #expect(transition.state.lifecycle == .disconnected)
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.terminal?.state.subscribed == false)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.state.retryAcquire == false)
        #expect(transition.state.presentationRevision == before.presentationRevision + 1)
        #expect(transition.effects == [])
    }

    @Test func resizeDisconnectedMarksTheWorkspaceReadOnly() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .resizeCompleted(runtime: runtimeA, outcome: .disconnected)
        )
        #expect(transition.state.lifecycle == .disconnected)
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.terminal?.state.subscribed == false)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.state.retryAcquire == false)
        #expect(transition.state.presentationRevision == before.presentationRevision + 1)
        #expect(transition.effects == [])
    }

    @Test func acquireSuccessClaimsOrReleases() {
        var before = connectedState(leasedRuntime: nil)
        before.terminal?.state.lease = .readOnly
        let claimed = WorkspaceTUIReducer.reduce(before, .acquireCompleted(runtime: runtimeA, outcome: .ok))
        #expect(claimed.state.terminal?.state.lease == .owned)
        #expect(claimed.state.leasedRuntime == runtimeA)
        #expect(claimed.effects == [])

        var stale = claimed.state
        stale.lifecycle = .disconnected
        let released = WorkspaceTUIReducer.reduce(stale, .acquireCompleted(runtime: runtimeA, outcome: .ok))
        #expect(released.effects == [.release(runtime: runtimeA)])
        #expect(released.state.leasedRuntime == runtimeA)

        let busy = WorkspaceTUIReducer.reduce(before, .acquireCompleted(runtime: runtimeA, outcome: .busy))
        #expect(busy.state.terminal?.state.lease == .readOnly)
        #expect(busy.effects == [])
    }

    @Test func resizeUnavailableExitsTheTerminal() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .resizeCompleted(runtime: runtimeA, outcome: .unavailable)
        )
        #expect(transition.state.terminal?.state.running == false)
        #expect(transition.state.terminal?.state.exitStatus == nil)
        #expect(transition.state.terminal?.state.lease == .released)
        #expect(transition.state.mode == .launcher)
    }

    @Test func subscribeSuccessAcquiresInEveryContext() {
        let before = connectedState()
        for context in [TUISubscribeContext.connect, .ensure, .launch] {
            let transition = WorkspaceTUIReducer.reduce(
                before,
                .subscribeCompleted(runtime: runtimeA, context: context, succeeded: true, disconnected: false)
            )
            #expect(transition.state.terminal?.state.subscribed == true)
            #expect(transition.effects == [.acquire(runtime: runtimeA)])
        }
    }

    @Test func connectSubscribeFailureStillAcquiresUnlessDisconnected() {
        var before = connectedState()
        before.terminal?.state.subscribed = false
        let rejected = WorkspaceTUIReducer.reduce(
            before,
            .subscribeCompleted(runtime: runtimeA, context: .connect, succeeded: false, disconnected: false)
        )
        #expect(rejected.effects == [.acquire(runtime: runtimeA)])
        #expect(rejected.state.lifecycle == .connected)
        let dropped = WorkspaceTUIReducer.reduce(
            before,
            .subscribeCompleted(runtime: runtimeA, context: .connect, succeeded: false, disconnected: true)
        )
        #expect(dropped.effects == [])
        #expect(dropped.state.lifecycle == .disconnected)
    }

    @Test func ensureSubscribeFailureMarksTheTerminalUnavailable() {
        var before = connectedState()
        before.terminal?.state.lease = .released
        before.terminal?.state.subscribed = false
        before.leasedRuntime = nil
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .subscribeCompleted(runtime: runtimeA, context: .ensure, succeeded: false, disconnected: false)
        )
        #expect(transition.state.terminal?.state.title == "shell (unavailable)")
        #expect(transition.state.terminal?.state.subscribed == false)
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.effects == [])
    }

    @Test func launchSubscribeFailureDropsTheTerminalAndCancels() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .subscribeCompleted(runtime: runtimeA, context: .launch, succeeded: false, disconnected: false)
        )
        #expect(transition.state.terminal == nil)
        #expect(transition.state.mode == .launcher)
        #expect(transition.effects == [.dropEmulator(runtime: runtimeA), .cancel(runtime: runtimeA)])
    }

    @Test func ensureSubscribeFailureWhileDisconnectedStillMarksTheTerminalUnavailable() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .subscribeCompleted(runtime: runtimeA, context: .ensure, succeeded: false, disconnected: true)
        )
        #expect(transition.state.lifecycle == .disconnected)
        #expect(transition.state.terminal?.state.title == "shell (unavailable)")
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.terminal?.state.subscribed == false)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.effects == [])
    }

    @Test func launchSubscribeFailureWhileDisconnectedDropsTheTerminalWithoutTheLauncher() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .subscribeCompleted(runtime: runtimeA, context: .launch, succeeded: false, disconnected: true)
        )
        #expect(transition.state.lifecycle == .disconnected)
        #expect(transition.state.terminal == nil)
        #expect(transition.state.mode == .terminal)
        #expect(transition.effects == [.dropEmulator(runtime: runtimeA), .cancel(runtime: runtimeA)])
    }

    @Test func detachReleasesUnsubscribesAndIsIdempotent() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .detachRequested)
        #expect(transition.effects == [
            .release(runtime: runtimeA),
            .unsubscribe(runtime: runtimeA),
            .detach,
        ])
        #expect(transition.state.lifecycle == .detached)
        #expect(transition.state.shouldExit)
        #expect(transition.state.terminal?.state.lease == .released)
        #expect(transition.state.terminal?.state.subscribed == false)
        let again = WorkspaceTUIReducer.reduce(transition.state, .detachRequested)
        #expect(again.effects == [])
        #expect(again.state == transition.state)
    }

    @Test func detachWithoutLeaseOrSubscriptionOnlyDetaches() {
        let before = connectedState(terminal: nil, leasedRuntime: nil)
        let transition = WorkspaceTUIReducer.reduce(before, .detachRequested)
        #expect(transition.effects == [.detach])
    }

    @Test func completionsThatRaceDetachLeaveDetachedStateAlone() {
        let detached = WorkspaceTUIReducer.reduce(connectedState(), .detachRequested).state
        let racing: [WorkspaceTUIReducerEvent] = [
            .hostDisconnected,
            .writeCompleted(runtime: runtimeA, outcome: .busy),
            .writeCompleted(runtime: runtimeA, outcome: .disconnected),
            .acquireCompleted(runtime: runtimeA, outcome: .busy),
            .acquireCompleted(runtime: runtimeA, outcome: .disconnected),
            .resizeCompleted(runtime: runtimeA, outcome: .unavailable),
            .resizeCompleted(runtime: runtimeA, outcome: .disconnected),
            .subscribeCompleted(runtime: runtimeA, context: .connect, succeeded: true, disconnected: false),
            .subscribeCompleted(runtime: runtimeA, context: .ensure, succeeded: false, disconnected: false),
            .subscribeCompleted(runtime: runtimeA, context: .launch, succeeded: false, disconnected: false),
        ]
        for event in racing {
            let transition = WorkspaceTUIReducer.reduce(detached, event)
            #expect(transition.effects == [])
            #expect(transition.state == detached)
        }
    }

    @Test func orphanedAcquireAfterDetachStillReleasesWithoutMutating() {
        let detached = WorkspaceTUIReducer.reduce(connectedState(), .detachRequested).state
        let transition = WorkspaceTUIReducer.reduce(detached, .acquireCompleted(runtime: runtimeA, outcome: .ok))
        #expect(transition.effects == [.release(runtime: runtimeA)])
        #expect(transition.state == detached)
    }

    @Test func staleSubscribeSuccessSkipsTheAcquire() {
        var before = connectedState()
        before.terminal?.state.subscribed = false
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .subscribeCompleted(runtime: runtimeB, context: .connect, succeeded: true, disconnected: false)
        )
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func hostDisconnectedMarksTheWorkspaceReadOnly() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .hostDisconnected)
        #expect(transition.state.lifecycle == .disconnected)
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.terminal?.state.subscribed == false)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.effects == [])
    }

    @Test func scriptedConnectSequenceProducesTheExpectedTrace() {
        let start = initialState()
        let requested = WorkspaceTUIReducer.reduce(start, .connectRequested)
        #expect(requested.effects == [.queryConnect])

        let queried = WorkspaceTUIReducer.reduce(
            requested.state,
            .connectQuery(
                described: testSummary,
                runtimes: [ListedRuntime(id: runtimeA, hook: nil, running: true, terminal: true)]
            )
        )
        #expect(queried.effects == [
            .createEmulator(runtime: runtimeA, rows: 24, columns: 80),
            .subscribe(runtime: runtimeA, context: .connect),
        ])

        let subscribed = WorkspaceTUIReducer.reduce(
            queried.state,
            .subscribeCompleted(runtime: runtimeA, context: .connect, succeeded: true, disconnected: false)
        )
        #expect(subscribed.effects == [.acquire(runtime: runtimeA)])

        let acquired = WorkspaceTUIReducer.reduce(
            subscribed.state,
            .acquireCompleted(runtime: runtimeA, outcome: .ok)
        )
        #expect(acquired.effects == [])
        #expect(acquired.state.terminal?.state.lease == .owned)
        #expect(acquired.state.leasedRuntime == runtimeA)

        let typed = WorkspaceTUIReducer.reduce(acquired.state, .key(.character("a")))
        #expect(typed.effects == [.queueSend(runtime: runtimeA, bytes: Data("a".utf8))])

        let sent = WorkspaceTUIReducer.reduce(typed.state, .sendDue(runtime: runtimeA, bytes: Data("a".utf8)))
        #expect(sent.effects == [.write(runtime: runtimeA, bytes: Data("a".utf8))])
        #expect(sent.state == typed.state)
    }
}

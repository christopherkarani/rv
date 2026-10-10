import Foundation
import Testing
import RVDomain
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
private let paneID = PaneID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
private let testBinding = PaneBindingKey(pane: paneID, runtime: runtimeA, generation: 1)
private let emptyTarget = PrefixTarget(pane: paneID, generation: nil)
private let boundTarget = PrefixTarget(pane: paneID, generation: 1)

private func binding(_ runtime: UUID) -> PaneBindingKey {
    PaneBindingKey(pane: paneID, runtime: runtime, generation: runtime == runtimeB ? 2 : 1)
}

private extension TUIRuntimeEffect {
    static func ensureShell(choice: RuntimeLaunchChoice, rows: Int, columns: Int) -> Self {
        .ensureShell(target: emptyTarget, choice: choice, rows: rows, columns: columns)
    }
    static func queueSend(runtime: UUID, bytes: Data) -> Self {
        .queueSend(binding: binding(runtime), bytes: bytes)
    }
    static func queueKey(runtime: UUID, key: TUIKey) -> Self {
        .queueKey(binding: binding(runtime), key: key)
    }
    static func queueLaunch(choice: RuntimeLaunchChoice) -> Self {
        .queueLaunch(target: emptyTarget, choice: choice)
    }
    static func launchQuery(choice: RuntimeLaunchChoice, rows: Int, columns: Int) -> Self {
        .launchQuery(target: emptyTarget, choice: choice, rows: rows, columns: columns)
    }
    static func attach(runtime: UUID, context: TUIAttachContext) -> Self {
        .attach(binding: binding(runtime), context: context)
    }
    static func observe(runtime: UUID, context: TUIAttachContext) -> Self {
        .observe(binding: binding(runtime), context: context)
    }
    static func acquire(runtime: UUID) -> Self { .acquire(binding: binding(runtime)) }
    static func write(runtime: UUID, bytes: Data) -> Self {
        .write(binding: binding(runtime), bytes: bytes)
    }
    static func resize(runtime: UUID, rows: Int, columns: Int) -> Self {
        .resize(binding: binding(runtime), rows: rows, columns: columns)
    }
    static func createEmulator(runtime: UUID, rows: Int, columns: Int) -> Self {
        .createEmulator(binding: binding(runtime), rows: rows, columns: columns)
    }
    static func feedEmulator(runtime: UUID, data: Data) -> Self {
        .feedEmulator(binding: binding(runtime), data: data)
    }
    static func resizeEmulator(runtime: UUID, rows: Int, columns: Int) -> Self {
        .resizeEmulator(binding: binding(runtime), rows: rows, columns: columns)
    }
    static func dropEmulator(runtime: UUID) -> Self { .dropEmulator(binding: binding(runtime)) }
}

private extension WorkspaceTUIReducerEvent {
    static func ensureSucceeded(runtime: ListedRuntime, shell: RuntimeLaunchChoice) -> Self {
        .ensureSucceeded(target: emptyTarget, runtime: runtime, shell: shell)
    }
    static func ensureFailed(error: WorkspaceTUIError, profileID: String? = nil) -> Self {
        .ensureFailed(target: emptyTarget, error: error, profileID: profileID)
    }
    static func sendDue(runtime: UUID, bytes: Data) -> Self {
        .sendDue(binding: binding(runtime), bytes: bytes)
    }
    static func launchDue(choice: RuntimeLaunchChoice) -> Self {
        .launchDue(target: emptyTarget, choice: choice)
    }
    static func launchQuerySucceeded(
        choice: RuntimeLaunchChoice, runtime: ListedRuntime, rows: Int, columns: Int
    ) -> Self {
        .launchQuerySucceeded(target: boundTarget, choice: choice, runtime: runtime, rows: rows, columns: columns)
    }
    static func launchQueryFailed(choice: RuntimeLaunchChoice = shellChoice, error: WorkspaceTUIError) -> Self {
        .launchQueryFailed(target: boundTarget, choice: choice, error: error)
    }
    static func emulatorResponded(runtime: UUID, responses: [Data]) -> Self {
        .emulatorResponded(binding: binding(runtime), responses: responses)
    }
    static func writeCompleted(runtime: UUID, bytes: Data = Data(), outcome: TUIRPCOutcome) -> Self {
        .writeCompleted(binding: binding(runtime), bytes: bytes, outcome: outcome)
    }
    static func acquireCompleted(runtime: UUID, outcome: TUIRPCOutcome) -> Self {
        .acquireCompleted(binding: binding(runtime), outcome: outcome)
    }
    static func resizeCompleted(
        runtime: UUID, rows: Int = 24, columns: Int = 80, outcome: TUIRPCOutcome, now: Date = Date()
    ) -> Self {
        .resizeCompleted(binding: binding(runtime), rows: rows, columns: columns, outcome: outcome, now: now)
    }
    static func attachCompleted(runtime: UUID, context: TUIAttachContext, outcome: SessionAttachOutcome) -> Self {
        .attachCompleted(binding: binding(runtime), context: context, outcome: outcome)
    }
}

private func initialState(
    launcher: [RuntimeLaunchChoice] = [shellChoice, opencodeChoice],
    defaultShellID: String = "shell"
) -> WorkspaceTUIState {
    WorkspaceTUIState(
        lifecycle: .neverConnected,
        summary: testSummary,
        launcher: launcher,
        defaultShellID: defaultShellID,
        initialRows: 24,
        initialColumns: 80,
        mode: .terminal,
        terminal: nil,
        leasedRuntime: nil,
        retryAcquire: false,
        shouldExit: false,
        initialLaunchRequested: false,
        viewSize: nil,
        presentationRevision: 0,
        paneID: paneID
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
    // Heartbeat tests set their own clock; the shared fixture suppresses
    // the 5s probe so idle-tick assertions stay exact.
    state.lastSubscriptionProbeAt = .distantFuture
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
            .attach(runtime: runtimeA, context: .connect),
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

    @Test func restoredFocusedPaneKeepsItsBindingThroughInitAndReconcile() {
        let pane2 = PaneID()
        let tab = TabID()
        let restored = WorkspaceView(
            id: ViewID(),
            tabs: [WorkspaceTab(
                id: tab,
                tree: .split(SplitID(), .vertical, .half, .leaf(paneID), .leaf(pane2)),
                focusedPaneID: pane2
            )],
            activeTabID: tab,
            panes: [
                paneID: WorkspacePane(
                    id: paneID,
                    binding: RuntimeBinding(
                        workspace: WorkspaceSessionID(rawValue: testSummary.workspace),
                        runtime: RuntimeSessionID(rawValue: runtimeA), generation: 0),
                    lifecycle: .disconnected),
                pane2: WorkspacePane(
                    id: pane2,
                    binding: RuntimeBinding(
                        workspace: WorkspaceSessionID(rawValue: testSummary.workspace),
                        runtime: RuntimeSessionID(rawValue: runtimeB), generation: 0),
                    lifecycle: .disconnected),
            ]
        )
        let state = WorkspaceTUIState(
            lifecycle: .neverConnected,
            summary: testSummary,
            launcher: [shellChoice, opencodeChoice],
            initialRows: 24,
            initialColumns: 80,
            mode: .terminal,
            terminal: nil,
            leasedRuntime: nil,
            retryAcquire: false,
            shouldExit: false,
            initialLaunchRequested: false,
            viewSize: nil,
            presentationRevision: 0,
            restoredView: restored
        )
        // The nil terminal seed must not wipe the focused pane's binding.
        #expect(state.view.panes[paneID]?.binding?.runtime.rawValue == runtimeA)
        #expect(state.view.panes[pane2]?.binding?.runtime.rawValue == runtimeB)
        let reconciled = WorkspaceTUIReducer.reduce(state, .connectQuery(described: testSummary, runtimes: [
            ListedRuntime(id: runtimeA, hook: nil, running: true, terminal: true),
            ListedRuntime(id: runtimeB, hook: nil, running: true, terminal: true),
        ]))
        #expect(reconciled.state.view.panes[paneID]?.lifecycle == .running)
        #expect(reconciled.state.view.panes[pane2]?.lifecycle == .running)
        #expect(reconciled.state.view.panes[pane2]?.binding?.runtime.rawValue == runtimeB)
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

    @Test func launchDefaultUsesOperatorDefaultShellVariant() {
        var variant = shellChoice
        variant.id = "shell:docs"
        variant.title = "shell · docs (default)"
        variant.resourceProfileID = "docs"
        var before = initialState(launcher: [shellChoice, variant], defaultShellID: "shell:docs")
        before.lifecycle = .connected
        let transition = WorkspaceTUIReducer.reduce(before, .launchDefaultRequested)
        #expect(transition.effects == [.ensureShell(choice: variant, rows: 24, columns: 80)])
    }

    @Test func launchDefaultFallsBackToPlainShellWhenDefaultMissing() {
        var before = initialState(launcher: [shellChoice], defaultShellID: "shell:gone")
        before.lifecycle = .connected
        let transition = WorkspaceTUIReducer.reduce(before, .launchDefaultRequested)
        #expect(transition.effects == [.ensureShell(choice: shellChoice, rows: 24, columns: 80)])
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
            .attach(runtime: runtimeA, context: .ensure),
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
        let rejected = WorkspaceTUIReducer.reduce(before, .ensureFailed(error: .rejected))
        #expect(rejected.state.mode == .launcher)
        #expect(rejected.state.lifecycle == .connected)
        let dropped = WorkspaceTUIReducer.reduce(before, .ensureFailed(error: .disconnected))
        #expect(dropped.state.lifecycle == .disconnected)
    }

    @Test func ensureFailedRendersTheDenial() {
        let before = connectedState(terminal: nil, leasedRuntime: nil)
        let staging = WorkspaceTUIReducer.reduce(
            before,
            .ensureFailed(
                error: .resourceStagingFailed("executable link 'grok'"), profileID: "agents"
            )
        )
        #expect(staging.state.mode == .launcher)
        #expect(staging.state.feedback
            == "Profile 'agents' staging failed: executable link 'grok' unusable")
        #expect(staging.state.feedbackTicks == 60)
        #expect(staging.state.view.panes[paneID]?.lifecycle == .launchFailed)
    }

    @Test func keySendQueuesTerminalWrite() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .key(.character("a")))
        #expect(transition.effects == [.queueKey(runtime: runtimeA, key: .character("a"))])
        #expect(transition.state.mode == .terminal)
        #expect(transition.state.presentationRevision == before.presentationRevision)
    }

    @Test func keyDetachSetsShouldExitWithoutEffects() {
        let before = connectedState()
        let prefixed = WorkspaceTUIReducer.reduce(before, .key(.control("b")))
        #expect(prefixed.state.mode == .prefix(PrefixTarget(
            pane: before.activePaneID!, generation: before.activeBindingKey?.generation
        )))
        #expect(prefixed.effects == [])
        let detached = WorkspaceTUIReducer.reduce(prefixed.state, .key(.character("q")))
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
        var before = connectedState()
        before.mode = .prefix(PrefixTarget(pane: before.activePaneID!, generation: before.activeBindingKey?.generation))
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
        let entered = WorkspaceTUIReducer.reduce(before, .key(.control("b")))
        #expect(entered.state.mode == .prefix(PrefixTarget(
            pane: before.activePaneID!, generation: before.activeBindingKey?.generation
        )))
        #expect(entered.effects == [])
        #expect(entered.state.presentationRevision == before.presentationRevision + 1)

        let cancelled = WorkspaceTUIReducer.reduce(entered.state, .key(.escape))
        #expect(cancelled.state.mode == .terminal)
        #expect(cancelled.effects == [])

        let launcher = WorkspaceTUIReducer.reduce(connectedState(mode: .launcher), .key(.character("x")))
        #expect(launcher.state.mode == .terminal)
        #expect(launcher.effects == [])
    }

    @Test func prefixCapturesBindingAndRejectsAChangedPaneBeforeDetach() {
        let before = connectedState()
        let prefixed = WorkspaceTUIReducer.reduce(before, .key(.control("b")))
        #expect(prefixed.effects.isEmpty)
        var rebound = prefixed.state
        rebound.terminal = attachedTerminal(runtime: runtimeB)
        let stale = WorkspaceTUIReducer.reduce(rebound, .key(.character("q")))
        #expect(stale.state.shouldExit == false)
        #expect(stale.state.mode == .terminal)
        #expect(stale.state.feedback != nil)
        #expect(stale.effects.isEmpty)
    }

    @Test func literalControlBSendsOneByteAndInvalidPrefixShowsTransientFeedback() {
        let before = connectedState()
        let prefixed = WorkspaceTUIReducer.reduce(before, .key(.control("b")))
        let literal = WorkspaceTUIReducer.reduce(prefixed.state, .key(.control("b")))
        #expect(literal.effects == [.queueSend(binding: testBinding, bytes: Data([0x02]))])
        #expect(literal.state.mode == .terminal)

        let invalid = WorkspaceTUIReducer.reduce(prefixed.state, .key(.character("s")))
        #expect(invalid.effects.isEmpty)
        #expect(invalid.state.feedback == "Unknown Ctrl-B command")
        var state = invalid.state
        for _ in 0..<60 { state = WorkspaceTUIReducer.reduce(state, .tick(now: Date())).state }
        #expect(state.feedback == nil)
    }

    @Test func staleBindingCompletionsCannotMutateReplacementPane() {
        var replaced = connectedState()
        replaced.terminal = attachedTerminal(runtime: runtimeB)
        #expect(replaced.activeBindingKey?.generation == 2)
        let staleWrite = WorkspaceTUIReducer.reduce(
            replaced, .writeCompleted(binding: testBinding, bytes: Data("z".utf8), outcome: .busy)
        )
        #expect(staleWrite.state == replaced)
        let staleResize = WorkspaceTUIReducer.reduce(
            replaced,
            .resizeCompleted(binding: testBinding, rows: 24, columns: 80, outcome: .unavailable, now: Date())
        )
        #expect(staleResize.state == replaced)
        let staleReply = WorkspaceTUIReducer.reduce(
            replaced, .emulatorResponded(binding: testBinding, responses: [Data("R".utf8)])
        )
        #expect(staleReply.effects.isEmpty)
    }

    @Test func sendDueWithoutLeaseHoldsTypeaheadForTheAttach() {
        var readOnly = connectedState()
        readOnly.leasedRuntime = nil
        readOnly.terminal?.state.lease = .readOnly
        let held = WorkspaceTUIReducer.reduce(readOnly, .sendDue(runtime: runtimeA, bytes: Data("a".utf8)))
        #expect(held.effects == [])
        #expect(held.state.panes[paneID]?.input?.binding == binding(runtimeA))
        #expect(held.state.panes[paneID]?.input?.bytes == Data("a".utf8))
        let heldMore = WorkspaceTUIReducer.reduce(held.state, .sendDue(runtime: runtimeA, bytes: Data("b".utf8)))
        #expect(heldMore.effects == [])
        #expect(heldMore.state.panes[paneID]?.input?.bytes == Data("ab".utf8))
    }

    @Test func leaseGrantFlushesQueuedTypeahead() {
        var readOnly = connectedState()
        readOnly.leasedRuntime = nil
        readOnly.terminal?.state.lease = .readOnly
        let held = WorkspaceTUIReducer.reduce(readOnly, .sendDue(runtime: runtimeA, bytes: Data("ab".utf8)))
        let attached = WorkspaceTUIReducer.reduce(
            held.state, .attachCompleted(runtime: runtimeA, context: .launch, outcome: .owned)
        )
        #expect(attached.effects == [.write(runtime: runtimeA, bytes: Data("ab".utf8))])
        #expect(attached.state.panes[paneID]?.input == nil)
    }

    @Test func acquireGrantFlushesQueuedTypeahead() {
        var readOnly = connectedState()
        readOnly.leasedRuntime = nil
        readOnly.terminal?.state.lease = .readOnly
        let held = WorkspaceTUIReducer.reduce(readOnly, .sendDue(runtime: runtimeA, bytes: Data("z".utf8)))
        let acquired = WorkspaceTUIReducer.reduce(
            held.state, .acquireCompleted(runtime: runtimeA, outcome: .ok)
        )
        #expect(acquired.effects == [.write(runtime: runtimeA, bytes: Data("z".utf8))])
        #expect(acquired.state.panes[paneID]?.input == nil)
    }

    @Test func typeaheadNeverFlushesIntoAStaleBinding() {
        var readOnly = connectedState()
        readOnly.leasedRuntime = nil
        readOnly.terminal?.state.lease = .readOnly
        let held = WorkspaceTUIReducer.reduce(readOnly, .sendDue(runtime: runtimeA, bytes: Data("stale".utf8)))
        var rebound = held.state
        rebound.terminal = attachedTerminal(runtime: runtimeB)
        #expect(rebound.panes[paneID]?.input == nil)
        let attached = WorkspaceTUIReducer.reduce(
            rebound, .attachCompleted(runtime: runtimeB, context: .launch, outcome: .owned)
        )
        #expect(attached.effects == [])
    }

    @Test func typeaheadIsBoundedToOneHostWrite() {
        var readOnly = connectedState()
        readOnly.leasedRuntime = nil
        readOnly.terminal?.state.lease = .readOnly
        let big = Data(repeating: 0x61, count: 4000)
        let held = WorkspaceTUIReducer.reduce(readOnly, .sendDue(runtime: runtimeA, bytes: big))
        let over = WorkspaceTUIReducer.reduce(
            held.state, .sendDue(runtime: runtimeA, bytes: Data(repeating: 0x62, count: 100))
        )
        #expect(over.state.panes[paneID]?.input?.bytes.count == 4096)
        #expect(over.state.panes[paneID]?.input?.bytes.prefix(4000) == big)
        #expect(over.state.panes[paneID]?.input?.bytes.suffix(96) == Data(repeating: 0x62, count: 96))
    }

    @Test func detachDropsQueuedTypeahead() {
        var readOnly = connectedState()
        readOnly.leasedRuntime = nil
        readOnly.terminal?.state.lease = .readOnly
        let held = WorkspaceTUIReducer.reduce(readOnly, .sendDue(runtime: runtimeA, bytes: Data("q".utf8)))
        #expect(held.state.panes[paneID]?.input != nil)
        let detached = WorkspaceTUIReducer.reduce(held.state, .detachRequested)
        #expect(detached.state.panes.values.allSatisfy { $0.input == nil })
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
        #expect(transition.effects == [.launchQuery(choice: shellChoice, rows: 28, columns: 88)])
        // A running terminal does not block an intentional replacement:
        // the success path stashes it as pending and preserves its output
        // until the new subscription attaches. Only an in-flight pending
        // replacement collapses a duplicate submit.
        let running = connectedState()
        let replacement = WorkspaceTUIReducer.reduce(
            running, .launchDue(target: boundTarget, choice: shellChoice)
        )
        #expect(replacement.effects == [
            .launchQuery(target: boundTarget, choice: shellChoice, rows: 24, columns: 80),
        ])
        var pending = running
        let previous = pending.panes[paneID]?.terminal
        pending.panes[paneID]?.phase = .launching(LaunchDetail(
            previous: previous,
            candidate: WorkspaceTUIState.PendingLaunch(
                binding: binding(runtimeB),
                terminal: attachedTerminal(runtime: runtimeB)
            )
        ))
        // A bound target matches the live binding, so only the in-flight
        // candidate can be responsible for the drop.
        #expect(WorkspaceTUIReducer.reduce(
            pending, .launchDue(target: boundTarget, choice: shellChoice)
        ).effects == [])
    }

    @Test func launchSucceededAttachesAndRotatesSubscription() {
        let exited = attachedTerminal(running: false, exitStatus: 0, lease: .released, subscribed: true)
        let before = connectedState(terminal: exited, leasedRuntime: nil, mode: .launcher)
        let runtime = ListedRuntime(id: runtimeB, hook: nil, running: true, terminal: true, created: true)
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .launchQuerySucceeded(choice: opencodeChoice, runtime: runtime, rows: 24, columns: 80)
        )
        #expect(transition.state.terminal?.state.runtime == runtimeA)
        #expect(transition.state.panes[paneID]?.phase.candidate?.binding.runtime == runtimeB)
        #expect(transition.state.mode == .terminal)
        #expect(transition.effects == [.attach(runtime: runtimeB, context: .launch)])
        let attached = WorkspaceTUIReducer.reduce(
            transition.state,
            .attachCompleted(runtime: runtimeB, context: .launch, outcome: .owned)
        )
        #expect(attached.state.terminal?.state.runtime == runtimeB)
        #expect(attached.state.terminal?.state.title == "opencode")
        #expect(attached.effects == [
            .release(runtime: runtimeA), .dropEmulator(runtime: runtimeA),
            .createEmulator(runtime: runtimeB, rows: 24, columns: 80),
        ])
    }

    @Test func launchSucceededWhileRunningStashesAPendingReplacement() {
        // A success that matches the live binding is an intentional
        // replacement (launcher/run-command over a running pane): the old
        // terminal and its output stay until the new attach lands.
        // Genuinely stale successes (rebound generation) are still dropped
        // by matches(), and detached races stay host-owned.
        let before = connectedState()
        let runtime = ListedRuntime(id: runtimeB, hook: nil, running: true, terminal: true, created: true)
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .launchQuerySucceeded(choice: shellChoice, runtime: runtime, rows: 24, columns: 80)
        )
        #expect(transition.state.terminal?.state.runtime == runtimeA)
        #expect(transition.state.panes[paneID]?.phase.candidate?.binding.runtime == runtimeB)
        #expect(transition.effects == [.attach(runtime: runtimeB, context: .launch)])
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
        let transition = WorkspaceTUIReducer.reduce(before, .launchQueryFailed(error: .unavailable))
        #expect(transition.state.mode == .launcher)
        #expect(transition.effects == [])
    }

    @Test func launchProfileRefusalEchoesIDAndHints() {
        var choice = shellChoice
        choice.id = "shell:docs"
        choice.resourceProfileID = "docs"
        let before = connectedState(mode: .terminal)
        let transition = WorkspaceTUIReducer.reduce(
            before, .launchQueryFailed(choice: choice, error: .resourceProfileUnavailable)
        )
        #expect(transition.state.mode == .launcher)
        #expect(transition.effects == [])
        #expect(transition.state.view.panes[paneID]?.lastOutcome == .launchFailed("Resource profile 'docs' unavailable"))
        #expect(transition.state.feedback == "Unknown id, wrong project, or changed policy — pick again")
        #expect(transition.state.feedbackTicks == 60)
    }

    @Test func launchStagingRefusalNamesTheGrant() {
        var choice = shellChoice
        choice.id = "shell:agents"
        choice.resourceProfileID = "agents"
        let before = connectedState(mode: .terminal)
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .launchQueryFailed(
                choice: choice, error: .resourceStagingFailed("credential '.config/auth'")
            )
        )
        #expect(transition.state.mode == .launcher)
        #expect(transition.state.view.panes[paneID]?.lastOutcome
            == .launchFailed("Profile 'agents' staging failed: credential '.config/auth' unusable"))
        #expect(transition.state.feedback
            == "Profile 'agents' staging failed: credential '.config/auth' unusable")
        #expect(transition.state.feedbackTicks == 60)
    }

    @Test func launchProfileRefusalWithoutIDStaysGeneric() {
        let before = connectedState(mode: .terminal)
        let transition = WorkspaceTUIReducer.reduce(
            before, .launchQueryFailed(error: .resourceProfileUnavailable)
        )
        #expect(transition.state.view.panes[paneID]?.lastOutcome == .launchFailed("Resource profile unavailable"))
        #expect(transition.state.feedback == "Unknown id, wrong project, or changed policy — pick again")
    }

    @Test func otherLaunchFailuresRenderTheirMessage() {
        let before = connectedState(mode: .terminal)
        let transition = WorkspaceTUIReducer.reduce(before, .launchQueryFailed(error: .unavailable))
        #expect(transition.state.feedback == "Runtime unavailable")
        #expect(transition.state.feedbackTicks == 60)
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

    @Test func overflowResubscribesWhileRunning() {
        // The host drops an overflowed subscription; without a resubscribe
        // the pane goes dark and input acquire fails closed. The reducer
        // re-attaches synchronously so output and the lease resume.
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .hostEvents([.overflow(runtime: runtimeA)]))
        #expect(transition.effects == [.attach(runtime: runtimeA, context: .resubscribe)])
        #expect(transition.state.terminal(for: paneID)?.state.overflowed == true)
        #expect(transition.state.terminal(for: paneID)?.state.subscribed == false)
        #expect(transition.state.presentationRevision == before.presentationRevision + 1)
    }

    @Test func overflowOnExitedPaneDoesNotResubscribe() {
        let before = connectedState(terminal: attachedTerminal(running: false))
        let transition = WorkspaceTUIReducer.reduce(before, .hostEvents([.overflow(runtime: runtimeA)]))
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func resubscribeSuccessClearsOverflowAndRestoresLease() {
        var before = connectedState(leasedRuntime: nil)
        before.updateTerminal(paneID) {
            $0.state.overflowed = true
            $0.state.subscribed = false
        }
        let transition = WorkspaceTUIReducer.reduce(
            before, .attachCompleted(runtime: runtimeA, context: .resubscribe, outcome: .owned)
        )
        #expect(transition.state.terminal(for: paneID)?.state.overflowed == false)
        #expect(transition.state.terminal(for: paneID)?.state.subscribed == true)
        #expect(transition.state.terminal(for: paneID)?.state.lease == .owned)
        #expect(transition.state.leasedRuntime == runtimeA)
    }

    @Test func resubscribeContendedClearsOverflowStaysReadOnly() {
        var before = connectedState(leasedRuntime: nil)
        before.updateTerminal(paneID) {
            $0.state.overflowed = true
            $0.state.subscribed = false
            $0.state.lease = .readOnly
        }
        let transition = WorkspaceTUIReducer.reduce(
            before, .attachCompleted(runtime: runtimeA, context: .resubscribe, outcome: .readOnly)
        )
        #expect(transition.state.terminal(for: paneID)?.state.overflowed == false)
        #expect(transition.state.terminal(for: paneID)?.state.subscribed == true)
        #expect(transition.state.terminal(for: paneID)?.state.lease == .readOnly)
        #expect(transition.state.leasedRuntime == nil)
    }

    @Test func resubscribeFailureRetriesOnTick() {
        var before = connectedState()
        before.updateTerminal(paneID) {
            $0.state.overflowed = true
            $0.state.subscribed = false
        }
        let failed = WorkspaceTUIReducer.reduce(
            before, .attachCompleted(runtime: runtimeA, context: .resubscribe, outcome: .unavailable)
        )
        #expect(failed.state.panes[paneID]?.retries.contains(.subscribe) == true)
        #expect(failed.state.terminal(for: paneID)?.state.subscribed == false)
        let retried = WorkspaceTUIReducer.reduce(failed.state, .tick(now: Date()))
        #expect(retried.effects == [.attach(runtime: runtimeA, context: .resubscribeRetry)])
        #expect(retried.state.panes.values.allSatisfy { $0.retries.contains(.subscribe) == false })
    }

    @Test func resubscribeRetryFailureStaysQuiet() {
        // The tick retry is one-shot: a repeat failure means the runtime
        // is gone, so it must not re-arm and RPC-spam the tick.
        var before = connectedState()
        before.updateTerminal(paneID) {
            $0.state.overflowed = true
            $0.state.subscribed = false
        }
        let failed = WorkspaceTUIReducer.reduce(
            before, .attachCompleted(runtime: runtimeA, context: .resubscribeRetry, outcome: .unavailable)
        )
        #expect(failed.state.panes.values.allSatisfy { $0.retries.contains(.subscribe) == false })
        #expect(failed.effects == [])
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
        #expect(transition.state.viewSize == .init(rows: 32, columns: 92))
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

    @Test func tickProbesSubscriptionsEveryFiveSeconds() {
        let now = Date()
        var before = connectedState()
        before.lastSubscriptionProbeAt = now.addingTimeInterval(-6)
        let due = WorkspaceTUIReducer.reduce(before, .tick(now: now))
        #expect(due.effects == [.observe(runtime: runtimeA, context: .probe)])
        #expect(due.state.lastSubscriptionProbeAt == now)
        var fresh = connectedState()
        fresh.lastSubscriptionProbeAt = now
        let idle = WorkspaceTUIReducer.reduce(fresh, .tick(now: now))
        #expect(idle.effects == [])
        var unsubscribed = connectedState()
        unsubscribed.lastSubscriptionProbeAt = now.addingTimeInterval(-6)
        unsubscribed.updateTerminal(paneID) { $0.state.subscribed = false }
        let skipped = WorkspaceTUIReducer.reduce(unsubscribed, .tick(now: now))
        #expect(skipped.effects == [])
    }

    @Test func probeSuccessReclaimsLeaseWithoutFlopping() {
        // The host had silently dropped us; the probe's subscribe revived
        // the subscription. Claimants keep the lease and confirm it on
        // tick instead of flopping read-only and back.
        var before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before, .attachCompleted(runtime: runtimeA, context: .probe, outcome: .readOnly)
        )
        #expect(transition.state.terminal?.state.lease == .owned)
        #expect(transition.state.panes[paneID]?.retries.contains(.acquire) == true)
        #expect(transition.effects == [])
    }

    @Test func probeSuccessObserverStaysQuiet() {
        var before = connectedState(leasedRuntime: nil)
        before.terminal?.state.lease = .readOnly
        let transition = WorkspaceTUIReducer.reduce(
            before, .attachCompleted(runtime: runtimeA, context: .probe, outcome: .readOnly)
        )
        #expect(transition.effects == [])
        #expect(transition.state.panes.values.allSatisfy { $0.retries.contains(.acquire) == false })
    }

    @Test func probeFailureIsHealthyNoOp() {
        // Subscribe refused a duplicate: the existing subscription is
        // healthy. Touch nothing.
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before, .attachCompleted(runtime: runtimeA, context: .probe, outcome: .unavailable)
        )
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func writeBusyDowngradesTheLease() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .writeCompleted(runtime: runtimeA, outcome: .busy))
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.state.presentationRevision == before.presentationRevision + 1)
    }

    @Test func refusedWriteRearmsOneShotAcquire() {
        // A refused write on a subscribed pane may mean the host silently
        // dropped the subscription (overflow) rather than contention. One
        // acquire distinguishes: unavailable resubscribes, busy stays
        // quiet. Unsubscribed panes skip it; the subscribe loop owns them.
        var before = connectedState()
        let refused = WorkspaceTUIReducer.reduce(before, .writeCompleted(runtime: runtimeA, outcome: .busy))
        #expect(refused.state.panes[paneID]?.retries.contains(.acquire) == true)
        let ticked = WorkspaceTUIReducer.reduce(refused.state, .tick(now: Date()))
        #expect(ticked.effects == [.acquire(runtime: runtimeA)])
        before.updateTerminal(paneID) { $0.state.subscribed = false }
        let quiet = WorkspaceTUIReducer.reduce(before, .writeCompleted(runtime: runtimeA, outcome: .busy))
        #expect(quiet.state.panes.values.allSatisfy { $0.retries.contains(.acquire) == false })
    }

    @Test func refusedWriteRequeuesForNextGrant() {
        // Bytes refused by the host (overflow wedge, lost lease race) are
        // held as bounded typeahead and flushed by the next grant instead
        // of dropping the keystroke.
        let before = connectedState()
        let refused = WorkspaceTUIReducer.reduce(
            before, .writeCompleted(runtime: runtimeA, bytes: Data("z".utf8), outcome: .busy)
        )
        #expect(refused.state.panes[paneID]?.input?.bytes == Data("z".utf8))
        let granted = WorkspaceTUIReducer.reduce(
            refused.state, .acquireCompleted(runtime: runtimeA, outcome: .ok)
        )
        #expect(granted.effects == [.write(runtime: runtimeA, bytes: Data("z".utf8))])
        #expect(granted.state.panes[paneID]?.input == nil)
    }

    @Test func rejectedWriteSurfacesFeedback() {
        let before = connectedState()
        let oversize = WorkspaceTUIReducer.reduce(
            before,
            .writeCompleted(
                runtime: runtimeA,
                bytes: Data(repeating: 0x61, count: TerminalInputChunks.maximumTotalBytes + 1),
                outcome: .rejected
            )
        )
        #expect(oversize.state.feedback == "Input exceeds 1 MiB; rejected")
        #expect(oversize.state.feedbackTicks == 60)
        let small = WorkspaceTUIReducer.reduce(
            before, .writeCompleted(runtime: runtimeA, bytes: Data("z".utf8), outcome: .rejected)
        )
        #expect(small.state.feedback == "Write rejected; input dropped")
    }

    @Test func unavailableWriteWarnsOnlyWhileRunning() {
        var running = connectedState()
        running.updateTerminal(paneID) { $0.state.running = true }
        let warned = WorkspaceTUIReducer.reduce(
            running, .writeCompleted(runtime: runtimeA, bytes: Data("z".utf8), outcome: .unavailable)
        )
        #expect(warned.state.feedback == "Terminal unavailable; input dropped")
        var exited = connectedState()
        exited.updateTerminal(paneID) { $0.state.running = false }
        let quiet = WorkspaceTUIReducer.reduce(
            exited, .writeCompleted(runtime: runtimeA, bytes: Data("z".utf8), outcome: .unavailable)
        )
        #expect(quiet.state.feedback == nil)
        #expect(quiet.state == exited)
    }

    @Test func typeaheadTruncationSurfacesFeedback() {
        var readOnly = connectedState()
        readOnly.leasedRuntime = nil
        readOnly.terminal?.state.lease = .readOnly
        let big = Data(repeating: 0x61, count: 5000)
        let held = WorkspaceTUIReducer.reduce(readOnly, .sendDue(runtime: runtimeA, bytes: big))
        #expect(held.effects == [])
        #expect(held.state.panes[paneID]?.input?.bytes.count == 4096)
        #expect(held.state.feedback?.hasPrefix("Typeahead full; dropped ") == true)
        #expect(held.state.feedbackTicks == 60)
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

    @Test func acquireUnavailableOnSubscribedPaneResubscribes() {
        // Acquire fails unavailable only when the host has no subscription
        // for this client (a silent overflow drop) or the runtime is gone.
        // A pane that believes it is subscribed re-attaches instead of
        // wedging read-only with a dead subscription.
        for outcome: TUIRPCOutcome in [.unavailable, .rejected] {
            let before = connectedState()
            let transition = WorkspaceTUIReducer.reduce(before, .acquireCompleted(runtime: runtimeA, outcome: outcome))
            #expect(transition.effects == [.attach(runtime: runtimeA, context: .resubscribe)])
            #expect(transition.state.terminal(for: paneID)?.state.subscribed == false)
            #expect(transition.state.terminal(for: paneID)?.state.lease == .readOnly)
        }
    }

    @Test func acquireUnavailableOnUnsubscribedPaneStaysQuiet() {
        // No duplicate resubscribe: the subscribe-retry loop owns recovery
        // once the pane already knows it is unsubscribed.
        var before = connectedState()
        before.updateTerminal(paneID) { $0.state.subscribed = false }
        let transition = WorkspaceTUIReducer.reduce(before, .acquireCompleted(runtime: runtimeA, outcome: .unavailable))
        #expect(transition.effects == [])
        #expect(transition.state.terminal(for: paneID)?.state.lease == .readOnly)
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

    @Test func tickSkipsHostResizeWhileReadOnly() {
        var before = connectedState(leasedRuntime: nil)
        before.terminal?.state.lease = .readOnly
        let noted = WorkspaceTUIReducer.reduce(before, .sizeNoted(rows: 30, columns: 90, now: Date()))
        let settled = WorkspaceTUIReducer.reduce(noted.state, .tick(now: Date().addingTimeInterval(60)))
        #expect(settled.effects == [])
        #expect(settled.state.terminal?.resize.lastSentRows == 24)
        #expect(settled.state.terminal?.resize.lastSentColumns == 80)
        #expect(settled.state.terminal?.resize.pendingRows == 30)
        #expect(settled.state.terminal?.resize.pendingColumns == 90)
    }

    @Test func resizeBusyDowngradesLeaseAndRetriesAfterReacquire() {
        let start = Date()
        let before = connectedState()
        let noted = WorkspaceTUIReducer.reduce(before, .sizeNoted(rows: 30, columns: 90, now: start))
        let sent = WorkspaceTUIReducer.reduce(noted.state, .tick(now: start.addingTimeInterval(60)))
        #expect(sent.effects == [
            .resizeEmulator(runtime: runtimeA, rows: 30, columns: 90),
            .resize(runtime: runtimeA, rows: 30, columns: 90),
        ])
        let failed = WorkspaceTUIReducer.reduce(
            sent.state,
            .resizeCompleted(
                runtime: runtimeA, rows: 30, columns: 90, outcome: .busy,
                now: start.addingTimeInterval(61)
            )
        )
        #expect(failed.state.terminal?.state.lease == .readOnly)
        #expect(failed.state.leasedRuntime == nil)
        #expect(failed.state.terminal?.resize.lastSentRows == nil)
        #expect(failed.state.terminal?.resize.lastSentColumns == nil)
        #expect(failed.state.terminal?.resize.pendingRows == 30)
        #expect(failed.state.terminal?.resize.pendingColumns == 90)
        let reacquired = WorkspaceTUIReducer.reduce(failed.state, .acquireCompleted(runtime: runtimeA, outcome: .ok))
        #expect(reacquired.state.terminal?.state.lease == .owned)
        let retried = WorkspaceTUIReducer.reduce(reacquired.state, .tick(now: start.addingTimeInterval(62)))
        #expect(retried.effects == [
            .resizeEmulator(runtime: runtimeA, rows: 30, columns: 90),
            .resize(runtime: runtimeA, rows: 30, columns: 90),
        ])
    }

    @Test func resizeBusyForStaleSizeKeepsNewerPending() {
        let start = Date()
        let before = connectedState()
        let noted = WorkspaceTUIReducer.reduce(before, .sizeNoted(rows: 30, columns: 90, now: start))
        let sent = WorkspaceTUIReducer.reduce(noted.state, .tick(now: start.addingTimeInterval(60)))
        let moved = WorkspaceTUIReducer.reduce(
            sent.state, .sizeNoted(rows: 40, columns: 100, now: start.addingTimeInterval(61))
        )
        let stale = WorkspaceTUIReducer.reduce(
            moved.state,
            .resizeCompleted(
                runtime: runtimeA, rows: 30, columns: 90, outcome: .busy,
                now: start.addingTimeInterval(62)
            )
        )
        #expect(stale.state.terminal?.state.lease == .readOnly)
        #expect(stale.state.terminal?.resize.lastSentRows == nil)
        #expect(stale.state.terminal?.resize.pendingRows == 40)
        #expect(stale.state.terminal?.resize.pendingColumns == 100)
    }

    @Test func attachOwnedClaimsTheLeaseInEveryContext() {
        var before = connectedState(leasedRuntime: nil)
        before.terminal?.state.lease = .readOnly
        before.terminal?.state.subscribed = false
        for context in [TUIAttachContext.connect, .ensure, .launch, .reconnect] {
            let transition = WorkspaceTUIReducer.reduce(
                before,
                .attachCompleted(runtime: runtimeA, context: context, outcome: .owned)
            )
            #expect(transition.state.terminal?.state.subscribed == true)
            #expect(transition.state.terminal?.state.lease == .owned)
            #expect(transition.state.leasedRuntime == runtimeA)
            #expect(transition.effects == [])
        }
    }

    @Test func attachReadOnlySubscribesWithoutTheLease() {
        var before = connectedState(leasedRuntime: nil)
        before.terminal?.state.lease = .released
        before.terminal?.state.subscribed = false
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .attachCompleted(runtime: runtimeA, context: .connect, outcome: .readOnly)
        )
        #expect(transition.state.terminal?.state.subscribed == true)
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.effects == [])
    }

    @Test func connectAttachUnavailableAcquiresNothing() {
        var before = connectedState()
        before.terminal?.state.subscribed = false
        let refused = WorkspaceTUIReducer.reduce(
            before,
            .attachCompleted(runtime: runtimeA, context: .connect, outcome: .unavailable)
        )
        #expect(refused.effects == [])
        #expect(refused.state.lifecycle == .connected)
        #expect(refused.state.terminal?.state.subscribed == false)
        #expect(refused.state.terminal?.state.lease == .readOnly)
        let dropped = WorkspaceTUIReducer.reduce(
            before,
            .attachCompleted(runtime: runtimeA, context: .connect, outcome: .disconnected)
        )
        #expect(dropped.effects == [])
        #expect(dropped.state.lifecycle == .disconnected)
    }

    @Test func ensureAttachUnavailableMarksTheTerminalUnavailable() {
        var before = connectedState()
        before.terminal?.state.lease = .released
        before.terminal?.state.subscribed = false
        before.leasedRuntime = nil
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .attachCompleted(runtime: runtimeA, context: .ensure, outcome: .unavailable)
        )
        #expect(transition.state.terminal?.state.title == "shell (unavailable)")
        #expect(transition.state.terminal?.state.subscribed == false)
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.effects == [])
    }

    @Test func launchAttachUnavailableDoesNotCancelTheHostRuntime() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .attachCompleted(runtime: runtimeA, context: .launch, outcome: .unavailable)
        )
        #expect(transition.state.terminal?.state.runtime == runtimeA)
        #expect(transition.state.mode == .launcher)
        #expect(transition.effects.isEmpty)
        #expect(transition.state.view.focusedPane?.lifecycle == .launchFailed)
    }

    @Test func ensureAttachDisconnectedStillMarksTheTerminalUnavailable() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .attachCompleted(runtime: runtimeA, context: .ensure, outcome: .disconnected)
        )
        #expect(transition.state.lifecycle == .disconnected)
        #expect(transition.state.terminal?.state.title == "shell (unavailable)")
        #expect(transition.state.terminal?.state.lease == .readOnly)
        #expect(transition.state.terminal?.state.subscribed == false)
        #expect(transition.state.leasedRuntime == nil)
        #expect(transition.effects == [])
    }

    @Test func launchAttachDisconnectedKeepsTheRuntimeDiscoverable() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .attachCompleted(runtime: runtimeA, context: .launch, outcome: .disconnected)
        )
        #expect(transition.state.lifecycle == .disconnected)
        #expect(transition.state.terminal?.state.runtime == runtimeA)
        #expect(transition.state.mode == .terminal)
        #expect(transition.effects.isEmpty)
    }

    @Test func detachReleasesOnceAndIsIdempotent() {
        let before = connectedState()
        let transition = WorkspaceTUIReducer.reduce(before, .detachRequested)
        #expect(transition.effects == [
            .release(runtime: runtimeA),
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
            .attachCompleted(runtime: runtimeA, context: .connect, outcome: .readOnly),
            .attachCompleted(runtime: runtimeA, context: .connect, outcome: .unavailable),
            .attachCompleted(runtime: runtimeA, context: .ensure, outcome: .unavailable),
            .attachCompleted(runtime: runtimeA, context: .launch, outcome: .unavailable),
            .attachCompleted(runtime: runtimeA, context: .launch, outcome: .disconnected),
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

    @Test func orphanedAttachAfterDetachStillReleasesWithoutMutating() {
        let detached = WorkspaceTUIReducer.reduce(connectedState(), .detachRequested).state
        let transition = WorkspaceTUIReducer.reduce(
            detached,
            .attachCompleted(runtime: runtimeA, context: .connect, outcome: .owned)
        )
        #expect(transition.effects == [.release(runtime: runtimeA)])
        #expect(transition.state == detached)
    }

    @Test func staleAttachOwnedReleasesWithoutClaiming() {
        var before = connectedState()
        before.terminal?.state.subscribed = false
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .attachCompleted(runtime: runtimeB, context: .connect, outcome: .owned)
        )
        #expect(transition.effects == [.release(runtime: runtimeB)])
        #expect(transition.state == before)
    }

    @Test func staleAttachReadOnlyClaimsNothing() {
        var before = connectedState()
        before.terminal?.state.subscribed = false
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .attachCompleted(runtime: runtimeB, context: .connect, outcome: .readOnly)
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
            .attach(runtime: runtimeA, context: .connect),
        ])

        let attached = WorkspaceTUIReducer.reduce(
            queried.state,
            .attachCompleted(runtime: runtimeA, context: .connect, outcome: .owned)
        )
        #expect(attached.effects == [])
        #expect(attached.state.terminal?.state.subscribed == true)
        #expect(attached.state.terminal?.state.lease == .owned)
        #expect(attached.state.leasedRuntime == runtimeA)

        let typed = WorkspaceTUIReducer.reduce(attached.state, .key(.character("a")))
        #expect(typed.effects == [.queueKey(runtime: runtimeA, key: .character("a"))])

        let sent = WorkspaceTUIReducer.reduce(typed.state, .sendDue(runtime: runtimeA, bytes: Data("a".utf8)))
        #expect(sent.effects == [.write(runtime: runtimeA, bytes: Data("a".utf8))])
        #expect(sent.state == typed.state)
    }

    @Test func incompatibleHostMapsToRejectedOutcome() {
        #expect(TUIRPCOutcome.from(.failure(.incompatibleHost)) == .rejected)
    }
}

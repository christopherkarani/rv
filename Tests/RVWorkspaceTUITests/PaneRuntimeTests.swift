import Foundation
import Testing
import RVDomain
@testable import RVWorkspaceTUI

private let rtShell = RuntimeLaunchChoice(
    id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil
)
private let rtSummary = WorkspaceTUISummary(
    project: "/tmp/project",
    phase: "active",
    protected: true,
    workspace: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
)
private let rtRuntimeA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let rtRuntimeB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
private let rtPane = PaneID(UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!)

private func rtBinding(_ runtime: UUID) -> PaneBindingKey {
    PaneBindingKey(pane: rtPane, runtime: runtime, generation: runtime == rtRuntimeB ? 2 : 1)
}

private func rtAttached(
    runtime: UUID = rtRuntimeA,
    running: Bool = true,
    lease: InputLease = .owned,
    subscribed: Bool = true
) -> WorkspaceTUIState.AttachedTerminal {
    var resize = ResizeCoalescer()
    resize.recordLaunch(rows: 24, columns: 80)
    return WorkspaceTUIState.AttachedTerminal(
        state: WorkspaceTerminalState(
            runtime: runtime,
            title: "shell",
            running: running,
            lease: lease,
            subscribed: subscribed
        ),
        resize: resize
    )
}

private func rtConnected(
    terminal: WorkspaceTUIState.AttachedTerminal? = rtAttached(),
    leasedRuntime: UUID? = rtRuntimeA
) -> WorkspaceTUIState {
    var state = WorkspaceTUIState(
        lifecycle: .neverConnected,
        summary: rtSummary,
        launcher: [rtShell],
        initialRows: 24,
        initialColumns: 80,
        mode: .terminal,
        terminal: nil,
        leasedRuntime: nil,
        retryAcquire: false,
        shouldExit: false,
        initialLaunchRequested: true,
        viewSize: .init(rows: 40, columns: 100),
        presentationRevision: 1,
        paneID: rtPane
    )
    state.lifecycle = .connected
    if let terminal { state.terminal = terminal }
    if let leased = leasedRuntime { state.leasedRuntime = leased }
    state.lastSubscriptionProbeAt = .distantFuture
    return state
}

private func rtListed(_ runtime: UUID) -> ListedRuntime {
    ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)
}

/// Pane-state coherence: every stored lifecycle derives from its phase,
/// claims name the live binding, and candidates name their own pane.
private func expectCoherent(_ state: WorkspaceTUIState, sourceLocation: SourceLocation = #_sourceLocation) {
    for paneID in state.view.panes.keys {
        #expect(
            state.derivedLifecycle(for: paneID) == state.view.panes[paneID]?.lifecycle,
            sourceLocation: sourceLocation
        )
        if state.view.panes[paneID]?.lifecycle == .running {
            #expect(state.view.panes[paneID]?.binding != nil, sourceLocation: sourceLocation)
        }
        if let claim = state.panes[paneID]?.leaseClaim {
            #expect(claim == state.bindingKey(for: paneID), sourceLocation: sourceLocation)
        }
        if case .launching(let detail)? = state.panes[paneID]?.phase,
           let candidate = detail.candidate {
            #expect(candidate.binding.pane == paneID, sourceLocation: sourceLocation)
        }
    }
}

@Suite struct PaneRuntimeTests {
    @Test func paneStateStaysCoherentThroughAScriptedSession() {
        var state = rtConnected()
        let boundA = PrefixTarget(pane: rtPane, generation: 1)
        let boundB = PrefixTarget(pane: rtPane, generation: 2)
        let now = Date()
        let script: [WorkspaceTUIReducerEvent] = [
            .key(.character("a")),
            .sendDue(binding: rtBinding(rtRuntimeA), bytes: Data("a".utf8)),
            .writeCompleted(binding: rtBinding(rtRuntimeA), bytes: Data("a".utf8), outcome: .ok),
            .hostEvents([.bytes(runtime: rtRuntimeA, data: Data("hi".utf8))]),
            .hostEvents([.overflow(runtime: rtRuntimeA)]),
            .attachCompleted(binding: rtBinding(rtRuntimeA), context: .resubscribe, outcome: .owned),
            .hostEvents([.window(runtime: rtRuntimeA, rows: 17, columns: 53)]),
            .hostEvents([.inputOwner(runtime: rtRuntimeA, owned: false)]),
            .tick(now: now),
            .launchDue(target: boundA, choice: rtShell),
            .launchQuerySucceeded(
                target: boundA, choice: rtShell, runtime: rtListed(rtRuntimeB), rows: 24, columns: 80
            ),
            .attachCompleted(binding: rtBinding(rtRuntimeB), context: .launch, outcome: .owned),
            .paneSizeNoted(pane: rtPane, rows: 30, columns: 90, now: now),
            .tick(now: now.addingTimeInterval(60)),
            .resizeCompleted(
                binding: rtBinding(rtRuntimeB), rows: 30, columns: 90, outcome: .ok, now: now
            ),
            .hostEvents([.exited(runtime: rtRuntimeB, status: 0)]),
            .key(.enter),
            .launchDue(target: boundB, choice: rtShell),
            .launchQueryFailed(target: boundB, choice: rtShell, error: .unavailable),
            .hostDisconnected,
            .tick(now: now),
            .reconnectSucceeded(terminals: [rtListed(rtRuntimeA)]),
            .key(.control("b")),
            .key(.character("v")),
            .detachRequested,
        ]
        for event in script {
            let transition = WorkspaceTUIReducer.reduce(state, event)
            expectCoherent(transition.state)
            state = transition.state
        }
        // Spot-check the resting lifecycles the script passes through.
        var probe = rtConnected()
        probe = WorkspaceTUIReducer.reduce(
            probe,
            .launchQuerySucceeded(
                target: boundA, choice: rtShell, runtime: rtListed(rtRuntimeB), rows: 24, columns: 80
            )
        ).state
        #expect(probe.view.panes[rtPane]?.lifecycle == .attaching)
        probe = WorkspaceTUIReducer.reduce(
            probe,
            .attachCompleted(binding: rtBinding(rtRuntimeB), context: .launch, outcome: .owned)
        ).state
        #expect(probe.view.panes[rtPane]?.lifecycle == .running)
        probe = WorkspaceTUIReducer.reduce(probe, .hostEvents([.exited(runtime: rtRuntimeB, status: 0)])).state
        #expect(probe.view.panes[rtPane]?.lifecycle == .exited)
        probe = WorkspaceTUIReducer.reduce(probe, .hostDisconnected).state
        #expect(probe.view.panes[rtPane]?.lifecycle == .disconnected)
        probe = WorkspaceTUIReducer.reduce(probe, .reconnectSucceeded(terminals: [])).state
        #expect(probe.view.panes[rtPane]?.lifecycle == .missing)
    }

    @Test func contendedClaimantIgnoresWindowNotice() {
        // Desired vs observed: a claimant that lost a race renders
        // read-only but keeps its claim, and still takes the owner path
        // for window notices. Together with
        // windowNoticeResizesObserverEmulatorOnly (same observed lease,
        // different behavior) this proves the split is load-bearing.
        var state = rtConnected(leasedRuntime: rtRuntimeA)
        state.updateTerminal(rtPane) { $0.state.lease = .readOnly }
        #expect(state.leasedRuntime == rtRuntimeA)
        let transition = WorkspaceTUIReducer.reduce(
            state, .hostEvents([.window(runtime: rtRuntimeA, rows: 17, columns: 53)])
        )
        #expect(transition.effects == [])
    }

    @Test func overflowedObserverRetriesAcquireAndResubscribe() {
        // Both retry arms are reachable at once: an observer pane that
        // overflowed (subscribe arm) and then heard a free notice
        // (acquire arm). The tick fires both, acquire first.
        var state = rtConnected(
            terminal: rtAttached(lease: .readOnly, subscribed: true),
            leasedRuntime: nil
        )
        var transition = WorkspaceTUIReducer.reduce(state, .hostEvents([.overflow(runtime: rtRuntimeA)]))
        transition = WorkspaceTUIReducer.reduce(
            transition.state,
            .attachCompleted(binding: rtBinding(rtRuntimeA), context: .resubscribe, outcome: .unavailable)
        )
        transition = WorkspaceTUIReducer.reduce(
            transition.state, .hostEvents([.inputOwner(runtime: rtRuntimeA, owned: false)])
        )
        #expect(transition.state.panes[rtPane]?.retries == [.acquire, .subscribe])
        transition = WorkspaceTUIReducer.reduce(transition.state, .tick(now: Date()))
        #expect(transition.effects == [
            .acquire(binding: rtBinding(rtRuntimeA)),
            .attach(binding: rtBinding(rtRuntimeA), context: .resubscribeRetry),
        ])
        #expect(transition.state.panes[rtPane]?.retries.isEmpty == true)
    }

    @Test func lateReplacementSuccessAfterDisconnectReleasesInsteadOfClaiming() {
        // The host dies while a replacement attach is in flight: the
        // candidate is dropped with the launch, and the late success
        // releases instead of claiming on a dead connection.
        var state = rtConnected()
        let boundA = PrefixTarget(pane: rtPane, generation: 1)
        state = WorkspaceTUIReducer.reduce(state, .launchDue(target: boundA, choice: rtShell)).state
        state = WorkspaceTUIReducer.reduce(
            state,
            .launchQuerySucceeded(
                target: boundA, choice: rtShell, runtime: rtListed(rtRuntimeB), rows: 24, columns: 80
            )
        ).state
        #expect(state.panes[rtPane]?.phase.candidate?.binding.runtime == rtRuntimeB)
        state = WorkspaceTUIReducer.reduce(state, .hostDisconnected).state
        #expect(state.view.panes[rtPane]?.lifecycle == .disconnected)
        let late = WorkspaceTUIReducer.reduce(
            state, .attachCompleted(binding: rtBinding(rtRuntimeB), context: .launch, outcome: .owned)
        )
        #expect(late.effects == [.release(runtime: rtRuntimeB)])
        #expect(late.state.panes[rtPane]?.leaseClaim == nil)
        #expect(late.state.view.panes[rtPane]?.lifecycle == .disconnected)
        expectCoherent(late.state)
    }

    @Test func typeaheadSurvivesRenderPassGeometryNotes() {
        // Geometry notes must not disturb queued typeahead: the render
        // pass records sizes constantly, and wiping the queue there
        // would lose keystrokes the lease would otherwise flush.
        var readOnly = rtConnected(terminal: rtAttached(lease: .readOnly), leasedRuntime: nil)
        let held = WorkspaceTUIReducer.reduce(
            readOnly, .sendDue(binding: rtBinding(rtRuntimeA), bytes: Data("ab".utf8))
        )
        #expect(held.state.panes[rtPane]?.input?.bytes == Data("ab".utf8))
        let noted = WorkspaceTUIReducer.reduce(
            held.state, .sizeNoted(rows: 30, columns: 90, now: Date())
        )
        #expect(noted.effects == [])
        #expect(noted.state.panes[rtPane]?.input?.bytes == Data("ab".utf8))
        readOnly = noted.state
        let paneNoted = WorkspaceTUIReducer.reduce(
            readOnly, .paneSizeNoted(pane: rtPane, rows: 30, columns: 90, now: Date())
        )
        #expect(paneNoted.state.panes[rtPane]?.input?.bytes == Data("ab".utf8))
    }

    @Test func replacementOnUnsubscribedPaneReleasesNothingForPrevious() {
        // The old post-assign membership check could never fire
        // (assigning already dropped the old claim), so only a
        // subscribed previous runtime is released here.
        var state = rtConnected()
        state.updateTerminal(rtPane) { $0.state.subscribed = false }
        let boundA = PrefixTarget(pane: rtPane, generation: 1)
        state = WorkspaceTUIReducer.reduce(
            state,
            .launchQuerySucceeded(
                target: boundA, choice: rtShell, runtime: rtListed(rtRuntimeB), rows: 24, columns: 80
            )
        ).state
        let done = WorkspaceTUIReducer.reduce(
            state, .attachCompleted(binding: rtBinding(rtRuntimeB), context: .launch, outcome: .owned)
        )
        #expect(done.effects == [
            .dropEmulator(binding: rtBinding(rtRuntimeA)),
            .createEmulator(binding: rtBinding(rtRuntimeB), rows: 24, columns: 80),
        ])
    }

    @Test func resubscribeSuccessDuringReplacementKeepsAttaching() {
        // A resubscribe that lands while a replacement attach is in
        // flight updates the previous slot without disturbing the
        // candidate: the pane keeps reading attaching until that
        // attach decides it.
        var state = rtConnected()
        let boundA = PrefixTarget(pane: rtPane, generation: 1)
        state = WorkspaceTUIReducer.reduce(
            state,
            .launchQuerySucceeded(
                target: boundA, choice: rtShell, runtime: rtListed(rtRuntimeB), rows: 24, columns: 80
            )
        ).state
        let done = WorkspaceTUIReducer.reduce(
            state,
            .attachCompleted(binding: rtBinding(rtRuntimeA), context: .resubscribe, outcome: .owned)
        )
        #expect(done.state.view.panes[rtPane]?.lifecycle == .attaching)
        #expect(done.state.panes[rtPane]?.phase.candidate?.binding.runtime == rtRuntimeB)
        expectCoherent(done.state)
    }

    @Test func restoredLayoutWithGoneRuntimeReconcilesToMissing() {
        let tab = WorkspaceTab(id: TabID(), tree: .leaf(rtPane), focusedPaneID: rtPane)
        let view = WorkspaceView(
            id: ViewID(),
            tabs: [tab],
            activeTabID: tab.id,
            panes: [
                rtPane: WorkspacePane(
                    id: rtPane,
                    binding: RuntimeBinding(
                        workspace: WorkspaceSessionID(rawValue: rtSummary.workspace),
                        runtime: RuntimeSessionID(rawValue: rtRuntimeA),
                        generation: 0
                    ),
                    lifecycle: .disconnected
                ),
            ]
        )
        var state = WorkspaceTUIState(
            lifecycle: .neverConnected,
            summary: rtSummary,
            launcher: [rtShell],
            initialRows: 24,
            initialColumns: 80,
            mode: .terminal,
            terminal: nil,
            leasedRuntime: nil,
            retryAcquire: false,
            shouldExit: false,
            initialLaunchRequested: false,
            viewSize: .init(rows: 40, columns: 100),
            presentationRevision: 0,
            restoredView: view
        )
        var transition = WorkspaceTUIReducer.reduce(
            state, .connectQuery(described: rtSummary, runtimes: [])
        )
        #expect(transition.state.view.panes[rtPane]?.lifecycle == .missing)
        #expect(transition.state.panes[rtPane]?.phase == .missing(stale: nil))
        expectCoherent(transition.state)
        // The missing record holds scroll for the pane: entering scroll
        // pins the restored generation.
        state = transition.state
        transition = WorkspaceTUIReducer.reduce(state, .key(.control("b")))
        transition = WorkspaceTUIReducer.reduce(transition.state, .key(.character("[")))
        #expect(transition.state.mode == .scroll(pane: rtPane))
        #expect(transition.state.panes[rtPane]?.scroll == ScrollPosition(anchor: 0, generation: 0))
        expectCoherent(transition.state)
    }
}

@Suite struct PaneIdentityTests {
    @Test func unboundTargetMatchesOnlyUnboundPanes() {
        // PrefixTarget(nil) proceeds on an unbound pane ...
        var fresh = rtConnected(terminal: nil, leasedRuntime: nil)
        fresh.mode = .runCommand(input: "echo hi", error: nil)
        let target = PrefixTarget(pane: rtPane, generation: nil)
        let proceed = WorkspaceTUIReducer.reduce(
            fresh, .runCommandResolved(target: target, choice: rtShell)
        )
        #expect(proceed.effects == [.queueLaunch(target: target, choice: rtShell)])
        #expect(proceed.state.mode == .terminal)
        // ... but a nil generation never matches a bound pane.
        var bound = rtConnected()
        bound.mode = .runCommand(input: "echo hi", error: nil)
        let dropped = WorkspaceTUIReducer.reduce(
            bound, .runCommandResolved(target: target, choice: rtShell)
        )
        #expect(dropped.effects == [])
        #expect(dropped.state == bound)
    }

    @Test func boundTargetRequiresTheExactGeneration() {
        var bound = rtConnected()
        bound.mode = .runCommand(input: "echo hi", error: nil)
        let exact = PrefixTarget(pane: rtPane, generation: 1)
        let proceed = WorkspaceTUIReducer.reduce(
            bound, .runCommandResolved(target: exact, choice: rtShell)
        )
        #expect(proceed.effects == [.queueLaunch(target: exact, choice: rtShell)])
        let stale = PrefixTarget(pane: rtPane, generation: 0)
        let dropped = WorkspaceTUIReducer.reduce(
            bound, .runCommandResolved(target: stale, choice: rtShell)
        )
        #expect(dropped.effects == [])
        #expect(dropped.state == bound)
    }

    @Test func bindingKeyExistsOnlyForBoundPanes() {
        // PaneBindingKey requires a bound pane: unbound panes have no key ...
        let fresh = rtConnected(terminal: nil, leasedRuntime: nil)
        #expect(fresh.bindingKey(for: rtPane) == nil)
        // ... while bound panes produce the exact operational key.
        let bound = rtConnected()
        #expect(bound.bindingKey(for: rtPane) == rtBinding(rtRuntimeA))
    }
}

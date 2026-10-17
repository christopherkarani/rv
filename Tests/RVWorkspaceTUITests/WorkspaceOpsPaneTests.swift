import Foundation
import Testing
import RVDomain
import RVHistory
#if os(macOS)
import Darwin
#endif
@testable import RVWorkspaceTUI

private let opsShellChoice = RuntimeLaunchChoice(
    id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil
)
private let opsSummary = WorkspaceTUISummary(
    project: "/tmp/project",
    phase: "active",
    protected: true,
    workspace: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
)
private let opsPaneID = PaneID(UUID(uuidString: "00000000-0000-0000-0000-000000000031")!)
private let opsRuntime = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!

private func opsInitialState() -> WorkspaceTUIState {
    WorkspaceTUIState(
        lifecycle: .neverConnected,
        summary: opsSummary,
        launcher: [opsShellChoice],
        defaultShellID: "shell",
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
        paneID: opsPaneID
    )
}

private func opsEvent(
    seconds: Int,
    kind: AuditEventKind = .runtimeSession,
    decision: AuditDecision = .info,
    subject: String = "subject",
    reason: String? = nil,
    workspace: String? = nil,
    runtime: String? = nil,
    agent: String? = nil,
    source: String = "audit.jsonl",
    detail: [String: String] = [:]
) -> AuditEvent {
    AuditEvent(
        time: Date(timeIntervalSince1970: TimeInterval(seconds)),
        kind: kind,
        decision: decision,
        subject: subject,
        reason: reason,
        workspace: workspace,
        runtime: runtime,
        agent: agent,
        source: source,
        detail: detail
    )
}

/// Reducer-opened ops pane, unseeded.
private func opsOpenedState() -> WorkspaceTUIState {
    let opened = WorkspaceTUIReducer.reduce(opsInitialState(), .opsOpened(pane: opsPaneID))
    return opened.state
}

/// Reducer-opened and seeded with `count` runtime events, one second apart.
private func opsSeededState(count: Int = 5) -> WorkspaceTUIState {
    var state = opsOpenedState()
    let events = (0..<count).map { opsEvent(seconds: $0, subject: "event-\($0)") }
    let seeded = WorkspaceTUIReducer.reduce(
        state, .opsHistory(pane: opsPaneID, events: events, cursor: AuditCursor())
    )
    state = seeded.state
    // The shared fixture suppresses the 5s probe so idle-tick assertions
    // stay exact, like the reducer suite's connectedState.
    state.lastSubscriptionProbeAt = .distantFuture
    return state
}

@Suite struct WorkspaceOpsPaneFilterTests {
    @Test func cycleOrderIsAllDeniedAdmissionRuntimePolicy() {
        #expect(OpsPaneFilter.all.next() == .denied)
        #expect(OpsPaneFilter.denied.next() == .admission)
        #expect(OpsPaneFilter.admission.next() == .runtime)
        #expect(OpsPaneFilter.runtime.next() == .policy)
        #expect(OpsPaneFilter.policy.next() == .all)
    }

    @Test func allAdmitsEverything() {
        let event = opsEvent(seconds: 0, kind: .egressDenied, decision: .denied)
        #expect(OpsPaneFilter.all.admits(event))
    }

    @Test func deniedAdmitsDecisionsOnly() {
        #expect(OpsPaneFilter.denied.admits(opsEvent(seconds: 0, decision: .denied)))
        #expect(OpsPaneFilter.denied.admits(opsEvent(seconds: 0, decision: .allowed)) == false)
        #expect(OpsPaneFilter.denied.admits(opsEvent(seconds: 0, decision: .info)) == false)
    }

    @Test func admissionAdmitsAdmissionKinds() {
        #expect(OpsPaneFilter.admission.admits(opsEvent(seconds: 0, kind: .admission)))
        #expect(OpsPaneFilter.admission.admits(opsEvent(
            seconds: 0, kind: AuditEventKind(rawValue: "admission.pending")
        )))
        #expect(OpsPaneFilter.admission.admits(opsEvent(seconds: 0, kind: .runtimeSession)) == false)
    }

    @Test func runtimeAdmitsRuntimeWorkspaceAndAgentKinds() {
        for kind in [AuditEventKind.runtimeSession, .runtimeStarted, .runtimeEnded,
                     .workspace("created"), .agent("spawned")] {
            #expect(OpsPaneFilter.runtime.admits(opsEvent(seconds: 0, kind: kind)))
        }
        #expect(OpsPaneFilter.runtime.admits(opsEvent(seconds: 0, kind: .mcpCall)) == false)
        #expect(OpsPaneFilter.runtime.admits(opsEvent(seconds: 0, kind: .admission)) == false)
    }

    @Test func policyAdmitsMcpSecretAndCommandKinds() {
        for kind in [AuditEventKind.mcpCall, .mcpApproval, .secretUse, .commandDenied,
                     AuditEventKind(rawValue: "secret.rotated"),
                     AuditEventKind(rawValue: "command.allowed")] {
            #expect(OpsPaneFilter.policy.admits(opsEvent(seconds: 0, kind: kind)))
        }
        #expect(OpsPaneFilter.policy.admits(opsEvent(seconds: 0, kind: .runtimeSession)) == false)
        #expect(OpsPaneFilter.policy.admits(opsEvent(seconds: 0, kind: .egressDenied)) == false)
    }
}

@Suite struct WorkspaceOpsPaneFormatTests {
    @Test func rowFormatsClockKindDecisionSubjectAndSortedDetail() {
        let event = opsEvent(
            seconds: 12 * 3600 + 34 * 60 + 56,
            kind: .runtimeSession,
            decision: .info,
            subject: "ws-1",
            source: "runtime-sessions.jsonl",
            detail: ["host": "h", "backend": "b"]
        )
        #expect(OpsPaneFormat.row(event) == "12:34:56 runtime.session info ws-1 [backend=b host=h]")
    }

    @Test func rowOmitsBracketsWhenDetailIsEmpty() {
        let event = opsEvent(seconds: 0, kind: .commandDenied, decision: .denied, subject: "rm")
        #expect(OpsPaneFormat.row(event) == "00:00:00 command.denied denied rm")
    }

    @Test func detailRendersOneFieldPerLine() {
        let event = opsEvent(
            seconds: 0,
            kind: .admission,
            decision: .pending,
            subject: "deploy",
            reason: "awaiting approval",
            workspace: "ws",
            runtime: "rt",
            agent: "agent",
            source: "runtime-admission.jsonl",
            detail: ["requestID": "r1"]
        )
        #expect(OpsPaneFormat.detail(event) == """
            time: 1970-01-01T00:00:00Z
            kind: admission
            decision: pending
            subject: deploy
            reason: awaiting approval
            workspace: ws
            runtime: rt
            agent: agent
            source: runtime-admission.jsonl
            Detail:
              requestID=r1
            """)
    }

    @Test func detailSkipsAbsentOptionalsAndEmptyDetail() {
        let event = opsEvent(seconds: 61, kind: .mcpCall, decision: .allowed, subject: "tool")
        #expect(OpsPaneFormat.detail(event) == """
            time: 1970-01-01T00:01:01Z
            kind: mcp.call
            decision: allowed
            subject: tool
            source: audit.jsonl
            """)
    }
}

@Suite struct WorkspaceOpsPaneReducerTests {
    @Test func openMarksPaneOpsAndRequestsHistory() {
        let before = opsInitialState()
        let transition = WorkspaceTUIReducer.reduce(before, .opsOpened(pane: opsPaneID))
        #expect(transition.state.view.panes[opsPaneID]?.content == .ops)
        #expect(transition.state.ops[opsPaneID]?.loaded == false)
        #expect(transition.effects == [.loadOpsHistory(pane: opsPaneID)])
        #expect(transition.state.presentationRevision == before.presentationRevision + 1)
    }

    @Test func openIsIdempotentOnceLive() {
        let live = opsSeededState()
        let transition = WorkspaceTUIReducer.reduce(live, .opsOpened(pane: opsPaneID))
        #expect(transition.effects == [])
        #expect(transition.state == live)
    }

    @Test func openIgnoresUnknownPanes() {
        let before = opsInitialState()
        let transition = WorkspaceTUIReducer.reduce(before, .opsOpened(pane: PaneID()))
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func historySeedStoresEventsCursorAndPinsTail() {
        let before = opsOpenedState()
        let events = (0..<5).map { opsEvent(seconds: $0, subject: "event-\($0)") }
        let cursor = AuditCursor(positions: ["audit.jsonl": .init(offset: 99, inode: 7)])
        let transition = WorkspaceTUIReducer.reduce(
            before, .opsHistory(pane: opsPaneID, events: events, cursor: cursor)
        )
        let ops = try! #require(transition.state.ops[opsPaneID])
        #expect(ops.loaded)
        #expect(ops.events.map(\.subject) == ["event-0", "event-1", "event-2", "event-3", "event-4"])
        #expect(ops.cursor == cursor)
        #expect(ops.follow)
        #expect(ops.cursorIndex == 4)
        #expect(ops.scrollOffset == 0)
    }

    @Test func historySeedSortsAndCapsAt2000Newest() {
        let before = opsOpenedState()
        let events = (0..<2005).map { opsEvent(seconds: $0, subject: "event-\($0)") }.reversed()
        let transition = WorkspaceTUIReducer.reduce(
            before, .opsHistory(pane: opsPaneID, events: Array(events), cursor: AuditCursor())
        )
        let ops = try! #require(transition.state.ops[opsPaneID])
        #expect(ops.events.count == 2000)
        #expect(ops.events.first?.subject == "event-5")
        #expect(ops.events.last?.subject == "event-2004")
        #expect(ops.cursorIndex == 1999)
    }

    @Test func historyAfterCloseIsIgnored() {
        var before = opsOpenedState()
        before.ops.removeValue(forKey: opsPaneID)
        let transition = WorkspaceTUIReducer.reduce(
            before, .opsHistory(pane: opsPaneID, events: [opsEvent(seconds: 0)], cursor: AuditCursor())
        )
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func pollAppendsSortedAndAdvancesCursor() {
        let before = opsSeededState()
        let cursor = AuditCursor(positions: ["audit.jsonl": .init(offset: 10, inode: 1)])
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .opsPolled(
                pane: opsPaneID,
                events: [opsEvent(seconds: 6, subject: "new-6"), opsEvent(seconds: 5, subject: "new-5")],
                cursor: cursor
            )
        )
        let ops = try! #require(transition.state.ops[opsPaneID])
        #expect(ops.events.map(\.subject) == [
            "event-0", "event-1", "event-2", "event-3", "event-4", "new-5", "new-6",
        ])
        #expect(ops.cursor == cursor)
        #expect(ops.cursorIndex == 6)
    }

    @Test func pollDedupsExactSeedOverlap() {
        let before = opsSeededState()
        let overlap = [
            opsEvent(seconds: 4, subject: "event-4"),
            opsEvent(seconds: 5, subject: "new-5"),
        ]
        let transition = WorkspaceTUIReducer.reduce(
            before, .opsPolled(pane: opsPaneID, events: overlap, cursor: AuditCursor())
        )
        let ops = try! #require(transition.state.ops[opsPaneID])
        #expect(ops.events.map(\.subject) == [
            "event-0", "event-1", "event-2", "event-3", "event-4", "new-5",
        ])
    }

    @Test func pollCapsRingAt2000Newest() {
        var state = opsOpenedState()
        let seed = (0..<2000).map { opsEvent(seconds: $0, subject: "event-\($0)") }
        state = WorkspaceTUIReducer.reduce(
            state, .opsHistory(pane: opsPaneID, events: seed, cursor: AuditCursor())
        ).state
        let transition = WorkspaceTUIReducer.reduce(
            state,
            .opsPolled(
                pane: opsPaneID,
                events: [opsEvent(seconds: 2000, subject: "fresh")],
                cursor: AuditCursor()
            )
        )
        let ops = try! #require(transition.state.ops[opsPaneID])
        #expect(ops.events.count == 2000)
        #expect(ops.events.first?.subject == "event-1")
        #expect(ops.events.last?.subject == "fresh")
    }

    @Test func emptyPollAdvancesCursorWithoutPresenting() {
        let before = opsSeededState()
        let cursor = AuditCursor(positions: ["audit.jsonl": .init(offset: 10, inode: 1)])
        let transition = WorkspaceTUIReducer.reduce(
            before, .opsPolled(pane: opsPaneID, events: [], cursor: cursor)
        )
        #expect(transition.state.ops[opsPaneID]?.cursor == cursor)
        #expect(transition.state.presentationRevision == before.presentationRevision)
    }

    @Test func cursorMovePausesFollowAndKeepsRowVisible() {
        var before = opsSeededState(count: 40)
        before.ops[opsPaneID]?.viewportRows = 10
        #expect(before.ops[opsPaneID]?.follow == true)
        let transition = WorkspaceTUIReducer.reduce(before, .opsCursor(delta: -1))
        let ops = try! #require(transition.state.ops[opsPaneID])
        #expect(ops.follow == false)
        #expect(ops.cursorIndex == 38)
        #expect(ops.scrollOffset == 29)
    }

    @Test func scrollPausesFollowWithoutMovingCursor() {
        let before = opsSeededState(count: 40)
        let transition = WorkspaceTUIReducer.reduce(before, .opsScroll(delta: -5))
        let ops = try! #require(transition.state.ops[opsPaneID])
        #expect(ops.follow == false)
        #expect(ops.cursorIndex == 39)
        #expect(ops.scrollOffset == 11)
    }

    @Test func pollWhilePausedKeepsPosition() {
        var before = opsSeededState()
        before.ops[opsPaneID]?.moveCursor(by: -2)
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .opsPolled(pane: opsPaneID, events: [opsEvent(seconds: 9, subject: "new")], cursor: AuditCursor())
        )
        let ops = try! #require(transition.state.ops[opsPaneID])
        #expect(ops.follow == false)
        #expect(ops.cursorIndex == 2)
        #expect(ops.events.count == 6)
    }

    @Test func followOnAndTogglePinTail() {
        var before = opsSeededState()
        before.ops[opsPaneID]?.moveCursor(by: -2)
        let on = WorkspaceTUIReducer.reduce(before, .opsFollowOn)
        #expect(on.state.ops[opsPaneID]?.follow == true)
        #expect(on.state.ops[opsPaneID]?.cursorIndex == 4)
        let toggled = WorkspaceTUIReducer.reduce(on.state, .opsFollowToggle)
        #expect(toggled.state.ops[opsPaneID]?.follow == false)
        // Toggling back on re-pins; the cursor survives the pause.
        #expect(toggled.state.ops[opsPaneID]?.cursorIndex == 4)
    }

    @Test func filterNextCyclesAndClampsCursor() {
        var before = opsSeededState()
        before.ops[opsPaneID]?.events = (0..<50).map {
            opsEvent(seconds: $0, decision: $0 < 3 ? .denied : .info, subject: "event-\($0)")
        }
        before.ops[opsPaneID]?.tail()
        #expect(before.ops[opsPaneID]?.cursorIndex == 49)
        let transition = WorkspaceTUIReducer.reduce(before, .opsFilterNext)
        let ops = try! #require(transition.state.ops[opsPaneID])
        #expect(ops.filter == .denied)
        #expect(ops.filtered.count == 3)
        #expect(ops.cursorIndex == 2)
        #expect(ops.scrollOffset == 0)
    }

    @Test func detailOpensAtCursorAndCloses() {
        let before = opsSeededState()
        let opened = WorkspaceTUIReducer.reduce(before, .opsDetailOpened)
        #expect(opened.state.ops[opsPaneID]?.detailIndex == 4)
        let closed = WorkspaceTUIReducer.reduce(opened.state, .opsDetailClosed)
        #expect(closed.state.ops[opsPaneID]?.detailIndex == nil)
    }

    @Test func detailStaysClosedOnEmptyList() {
        let before = opsOpenedState()
        let transition = WorkspaceTUIReducer.reduce(before, .opsDetailOpened)
        #expect(transition.state.ops[opsPaneID]?.detailIndex == nil)
    }

    @Test func copyLineEmitsExactRow() {
        let before = opsSeededState(count: 3)
        let transition = WorkspaceTUIReducer.reduce(before, .opsCopy(mode: .line))
        #expect(transition.effects == [.copyOpsText(text: "00:00:02 runtime.session info event-2")])
    }

    @Test func copyViewportEmitsVisibleRows() {
        var before = opsSeededState(count: 30)
        before.ops[opsPaneID]?.viewportRows = 3
        before.ops[opsPaneID]?.scroll(by: -5)
        let transition = WorkspaceTUIReducer.reduce(before, .opsCopy(mode: .viewport))
        #expect(transition.effects == [.copyOpsText(text: """
            00:00:01 runtime.session info event-1
            00:00:02 runtime.session info event-2
            00:00:03 runtime.session info event-3
            """)])
    }

    @Test func copyRangeYanksAnchorSpanAndExitsVisual() {
        var before = opsSeededState(count: 10)
        before.ops[opsPaneID]?.moveCursor(by: -6)
        before.ops[opsPaneID]?.toggleAnchor()
        before.ops[opsPaneID]?.moveCursor(by: 2)
        let transition = WorkspaceTUIReducer.reduce(before, .opsCopy(mode: .range))
        #expect(transition.effects == [.copyOpsText(text: """
            00:00:03 runtime.session info event-3
            00:00:04 runtime.session info event-4
            00:00:05 runtime.session info event-5
            """)])
        #expect(transition.state.ops[opsPaneID]?.selectionAnchor == nil)
    }

    @Test func copyEmptyListReportsNothingToCopy() {
        let before = opsOpenedState()
        let transition = WorkspaceTUIReducer.reduce(before, .opsCopy(mode: .line))
        #expect(transition.effects == [])
        #expect(transition.state.feedback == "Nothing to copy")
    }

    @Test func copyViewportClampsOverscrolledOffsetToVisiblePage() {
        // A page scroll clamps to the last row, not the last page; the copy
        // must still cover the visible page, not the single stored row.
        var before = opsSeededState(count: 30)
        before.ops[opsPaneID]?.scroll(by: 24)
        #expect(before.ops[opsPaneID]?.scrollOffset == 29)
        let transition = WorkspaceTUIReducer.reduce(before, .opsCopy(mode: .viewport))
        guard transition.effects.count == 1, case .copyOpsText(let text) = transition.effects[0] else {
            Issue.record("expected one copy effect, got \(transition.effects)")
            return
        }
        let rows = text.split(separator: "\n")
        #expect(rows.count == 24)
        #expect(rows.first?.hasSuffix("event-6") == true)
        #expect(rows.last?.hasSuffix("event-29") == true)
    }

    @Test func copiesSanitizeControlBytesLikeTheDisplay() {
        var before = opsSeededState(count: 3)
        before.ops[opsPaneID]?.events[2] = opsEvent(seconds: 2, subject: "x\u{1b}[2Jy\nz")
        let line = WorkspaceTUIReducer.reduce(before, .opsCopy(mode: .line))
        #expect(line.effects == [.copyOpsText(text: "00:00:02 runtime.session info x[2Jy z")])
        var ranged = opsSeededState(count: 3)
        ranged.ops[opsPaneID]?.events[0] = opsEvent(seconds: 0, subject: "a\nb")
        ranged.ops[opsPaneID]?.events[1] = opsEvent(seconds: 1, subject: "c\u{07}d")
        ranged.ops[opsPaneID]?.moveCursor(by: -2)
        ranged.ops[opsPaneID]?.toggleAnchor()
        ranged.ops[opsPaneID]?.moveCursor(by: 1)
        let yanked = WorkspaceTUIReducer.reduce(ranged, .opsCopy(mode: .range))
        #expect(yanked.effects == [.copyOpsText(text: """
            00:00:00 runtime.session info a b
            00:00:01 runtime.session info cd
            """)])
    }

    @Test func anchorTogglesAtCursor() {
        let before = opsSeededState()
        let set = WorkspaceTUIReducer.reduce(before, .opsAnchorToggled)
        #expect(set.state.ops[opsPaneID]?.selectionAnchor == 4)
        let cleared = WorkspaceTUIReducer.reduce(set.state, .opsAnchorToggled)
        #expect(cleared.state.ops[opsPaneID]?.selectionAnchor == nil)
    }
}

@Suite struct WorkspaceOpsPaneKeyTests {
    @Test func prefixORoutesToOpenOpsPane() {
        let target = PrefixTarget(pane: opsPaneID, generation: nil)
        let routed = CommandPrefix.route(.character("o"), mode: .prefix(target), launcher: [opsShellChoice])
        #expect(routed == (.terminal, .openOpsPane))
    }

    @Test func openCommandConvertsEmptyPaneInPlace() {
        let prefixed = WorkspaceTUIReducer.reduce(opsInitialState(), .key(.control("b"))).state
        #expect(prefixed.mode == .prefix(PrefixTarget(pane: opsPaneID, generation: nil)))
        let transition = WorkspaceTUIReducer.reduce(prefixed, .key(.character("o")))
        #expect(transition.state.view.panes[opsPaneID]?.content == .ops)
        #expect(transition.effects == [.loadOpsHistory(pane: opsPaneID)])
    }

    @Test func openCommandOnBoundPaneOpensFreshOpsTab() {
        let initial = opsInitialState()
        let connected = WorkspaceTUIReducer.reduce(
            initial,
            .connectQuery(described: opsSummary, runtimes: [
                ListedRuntime(id: opsRuntime, hook: nil, running: true, terminal: true),
            ])
        ).state
        #expect(connected.view.panes[opsPaneID]?.binding != nil)
        let prefixed = WorkspaceTUIReducer.reduce(connected, .key(.control("b"))).state
        let transition = WorkspaceTUIReducer.reduce(prefixed, .key(.character("o")))
        #expect(transition.state.view.tabs.count == 2)
        let fresh = try! #require(transition.state.view.activeTab?.focusedPaneID)
        #expect(fresh != opsPaneID)
        #expect(transition.state.view.panes[fresh]?.content == .ops)
        #expect(transition.state.view.panes[opsPaneID]?.content == .terminal)
        #expect(transition.effects == [.loadOpsHistory(pane: fresh)])
    }

    @Test func openCommandOnOpsPaneIsIdempotent() {
        let live = opsSeededState()
        let prefixed = WorkspaceTUIReducer.reduce(live, .key(.control("b"))).state
        let transition = WorkspaceTUIReducer.reduce(prefixed, .key(.character("o")))
        #expect(transition.effects == [])
        #expect(transition.state.view.panes[opsPaneID]?.content == .ops)
        #expect(transition.state.ops[opsPaneID]?.events.count == 5)
    }

    @Test func movementKeysPauseAndArrowsMirrorJK() {
        let before = opsSeededState()
        let down = WorkspaceTUIReducer.reduce(before, .key(.character("j")))
        #expect(down.state.ops[opsPaneID]?.cursorIndex == 4)
        #expect(down.state.ops[opsPaneID]?.follow == false)
        let up = WorkspaceTUIReducer.reduce(before, .key(.character("k")))
        #expect(up.state.ops[opsPaneID]?.cursorIndex == 3)
        let arrowUp = WorkspaceTUIReducer.reduce(before, .key(.arrow(.up)))
        #expect(arrowUp.state.ops[opsPaneID]?.cursorIndex == 3)
        let arrowDown = WorkspaceTUIReducer.reduce(before, .key(.arrow(.down)))
        #expect(arrowDown.state.ops[opsPaneID]?.cursorIndex == 4)
        let arrowLeft = WorkspaceTUIReducer.reduce(before, .key(.arrow(.left)))
        #expect(arrowLeft.state.ops[opsPaneID]?.cursorIndex == 3)
        let arrowRight = WorkspaceTUIReducer.reduce(before, .key(.arrow(.right)))
        #expect(arrowRight.state.ops[opsPaneID]?.cursorIndex == 4)
    }

    @Test func pageKeysScrollByViewport() {
        var before = opsSeededState(count: 40)
        before.ops[opsPaneID]?.viewportRows = 10
        let seedScroll = try! #require(before.ops[opsPaneID]?.scrollOffset)
        let up = WorkspaceTUIReducer.reduce(before, .key(.pageUp))
        #expect(up.state.ops[opsPaneID]?.scrollOffset == seedScroll - 10)
        #expect(up.state.ops[opsPaneID]?.follow == false)
        let down = WorkspaceTUIReducer.reduce(up.state, .key(.pageDown))
        #expect(down.state.ops[opsPaneID]?.scrollOffset == seedScroll)
    }

    @Test func followKeysPinTailAndToggle() {
        var before = opsSeededState()
        before.ops[opsPaneID]?.moveCursor(by: -2)
        let followed = WorkspaceTUIReducer.reduce(before, .key(.character("f")))
        #expect(followed.state.ops[opsPaneID]?.follow == true)
        #expect(followed.state.ops[opsPaneID]?.cursorIndex == 4)
        let bottomed = WorkspaceTUIReducer.reduce(before, .key(.character("G")))
        #expect(bottomed.state.ops[opsPaneID]?.follow == true)
        #expect(bottomed.state.ops[opsPaneID]?.cursorIndex == 4)
        let toggled = WorkspaceTUIReducer.reduce(followed.state, .key(.character("F")))
        #expect(toggled.state.ops[opsPaneID]?.follow == false)
    }

    @Test func slashAndDotCycleFilter() {
        let before = opsSeededState()
        let slashed = WorkspaceTUIReducer.reduce(before, .key(.character("/")))
        #expect(slashed.state.ops[opsPaneID]?.filter == .denied)
        let dotted = WorkspaceTUIReducer.reduce(slashed.state, .key(.character(".")))
        #expect(dotted.state.ops[opsPaneID]?.filter == .admission)
    }

    @Test func enterOpensDetailAndEnterOrEscapeCloses() {
        let before = opsSeededState()
        let opened = WorkspaceTUIReducer.reduce(before, .key(.enter))
        #expect(opened.state.ops[opsPaneID]?.detailIndex == 4)
        // Other keys wait while the detail is open.
        let held = WorkspaceTUIReducer.reduce(opened.state, .key(.character("j")))
        #expect(held.state.ops[opsPaneID]?.detailIndex == 4)
        #expect(held.state.ops[opsPaneID]?.cursorIndex == 4)
        let closed = WorkspaceTUIReducer.reduce(opened.state, .key(.escape))
        #expect(closed.state.ops[opsPaneID]?.detailIndex == nil)
        let reopened = WorkspaceTUIReducer.reduce(before, .key(.enter))
        let enterClosed = WorkspaceTUIReducer.reduce(reopened.state, .key(.enter))
        #expect(enterClosed.state.ops[opsPaneID]?.detailIndex == nil)
    }

    @Test func visualYankCopiesRange() {
        var state = opsSeededState(count: 3)
        state = WorkspaceTUIReducer.reduce(state, .key(.character("k"))).state
        state = WorkspaceTUIReducer.reduce(state, .key(.character("k"))).state
        state = WorkspaceTUIReducer.reduce(state, .key(.character("v"))).state
        #expect(state.ops[opsPaneID]?.selectionAnchor == 0)
        state = WorkspaceTUIReducer.reduce(state, .key(.character("j"))).state
        let yanked = WorkspaceTUIReducer.reduce(state, .key(.character("y")))
        #expect(yanked.effects == [.copyOpsText(text: """
            00:00:00 runtime.session info event-0
            00:00:01 runtime.session info event-1
            """)])
        #expect(yanked.state.ops[opsPaneID]?.selectionAnchor == nil)
    }

    @Test func yankWithoutAnchorCopiesLine() {
        let before = opsSeededState(count: 3)
        let yanked = WorkspaceTUIReducer.reduce(before, .key(.character("y")))
        #expect(yanked.effects == [.copyOpsText(text: "00:00:02 runtime.session info event-2")])
    }

    @Test func yankViewportCopiesVisibleRows() {
        let before = opsSeededState(count: 30)
        let yanked = WorkspaceTUIReducer.reduce(before, .key(.character("Y")))
        guard yanked.effects.count == 1, case .copyOpsText(let text) = yanked.effects[0] else {
            Issue.record("expected one copy effect, got \(yanked.effects)")
            return
        }
        let rows = text.split(separator: "\n")
        #expect(rows.count == 24)
        #expect(rows.first?.hasPrefix("00:00:06") == true)
    }

    @Test func unknownKeysAreConsumedWithoutChange() {
        let before = opsSeededState()
        for key: TUIKey in [.character("z"), .character("1"), .escape, .tab, .backspace] {
            let transition = WorkspaceTUIReducer.reduce(before, .key(key))
            #expect(transition.effects == [])
            #expect(transition.state == before)
        }
    }

    @Test func controlBStillEntersPrefixFromOpsPane() {
        let before = opsSeededState()
        let transition = WorkspaceTUIReducer.reduce(before, .key(.control("b")))
        #expect(transition.state.mode == .prefix(PrefixTarget(pane: opsPaneID, generation: nil)))
    }

    @Test func disconnectedEnterStillRetriesReconnectOnOpsPane() {
        var before = opsSeededState()
        before.lifecycle = .disconnected
        let transition = WorkspaceTUIReducer.reduce(before, .key(.enter))
        #expect(transition.state.feedback == "Reconnecting…")
        #expect(transition.state.ops[opsPaneID]?.detailIndex == nil)
    }
}

@Suite struct WorkspaceOpsPaneTickTests {
    private var tickBase: Date { Date(timeIntervalSince1970: 1000) }

    @Test func tickPollsLoadedPanesOnThrottle() {
        let before = opsSeededState()
        let first = WorkspaceTUIReducer.reduce(before, .tick(now: tickBase))
        #expect(first.effects == [.pollOps(pane: opsPaneID, cursor: AuditCursor())])
        #expect(first.state.ops[opsPaneID]?.lastPollAt == tickBase)
        let throttled = WorkspaceTUIReducer.reduce(first.state, .tick(now: tickBase.addingTimeInterval(0.1)))
        #expect(throttled.effects == [])
        let due = WorkspaceTUIReducer.reduce(first.state, .tick(now: tickBase.addingTimeInterval(0.6)))
        #expect(due.effects == [.pollOps(pane: opsPaneID, cursor: AuditCursor())])
    }

    @Test func tickSeedsRestoredOpsPane() {
        var before = opsInitialState()
        before.updatePane(opsPaneID) { $0.content = .ops }
        let transition = WorkspaceTUIReducer.reduce(before, .tick(now: tickBase))
        #expect(transition.effects == [.loadOpsHistory(pane: opsPaneID)])
        #expect(transition.state.ops[opsPaneID]?.loaded == false)
    }

    @Test func tickSkipsUnloadedPane() {
        let before = opsOpenedState()
        let transition = WorkspaceTUIReducer.reduce(before, .tick(now: tickBase))
        #expect(transition.effects == [])
    }
}

@Suite struct WorkspaceOpsPaneLifecycleTests {
    @Test func autoLaunchSkipsOpsPane() {
        var before = opsOpenedState()
        before.lifecycle = .connected
        let transition = WorkspaceTUIReducer.reduce(before, .launchDefaultRequested)
        #expect(transition.effects == [])
        #expect(transition.state == before)
    }

    @Test func ensureCompletionIgnoresOpsPane() {
        var before = opsOpenedState()
        before.lifecycle = .connected
        let runtime = ListedRuntime(id: opsRuntime, hook: nil, running: true, terminal: true)
        let target = PrefixTarget(pane: opsPaneID, generation: nil)
        let succeeded = WorkspaceTUIReducer.reduce(
            before, .ensureSucceeded(target: target, runtime: runtime, shell: opsShellChoice)
        )
        #expect(succeeded.effects == [])
        #expect(succeeded.state.view.panes[opsPaneID]?.binding == nil)
    }

    @Test func explicitLaunchTakesOverOpsPane() {
        var before = opsSeededState()
        before.lifecycle = .connected
        let runtime = ListedRuntime(id: opsRuntime, hook: nil, running: true, terminal: true)
        let transition = WorkspaceTUIReducer.reduce(
            before,
            .launchQuerySucceeded(
                target: PrefixTarget(pane: opsPaneID, generation: nil),
                choice: opsShellChoice, runtime: runtime, rows: 24, columns: 80
            )
        )
        #expect(transition.state.view.panes[opsPaneID]?.content == .terminal)
        #expect(transition.state.ops[opsPaneID] == nil)
        #expect(transition.state.view.panes[opsPaneID]?.binding?.runtime.rawValue == opsRuntime)
    }

    @Test func closePaneDropsOpsRecord() {
        let seeded = opsSeededState()
        let prefixed = WorkspaceTUIReducer.reduce(seeded, .key(.control("b"))).state
        let transition = WorkspaceTUIReducer.reduce(prefixed, .key(.character("x")))
        #expect(transition.state.ops.isEmpty)
        #expect(transition.state.view.tabs.isEmpty)
        #expect(transition.state.shouldExit)
    }

    @Test func paneSizeNoteRecordsViewportRows() {
        var before = opsSeededState()
        before.lifecycle = .connected
        let transition = WorkspaceTUIReducer.reduce(
            before, .paneSizeNoted(pane: opsPaneID, rows: 40, columns: 100, now: Date())
        )
        #expect(transition.state.ops[opsPaneID]?.viewportRows == 40)
    }

    @Test func opsContentValidatesAndPersistsThroughEqualIgnoringFocus() {
        let ops = opsSeededState().view
        #expect(ops.validate().isEmpty)
        let terminal = ops.updatingPane(WorkspacePane(id: opsPaneID))!
        #expect(terminal.validate().isEmpty)
        #expect(ops.equalIgnoringFocus(terminal) == false)
        #expect(ops.equalIgnoringFocus(ops))
    }

    @Test func renderPlanIgnoresContent() {
        let opsView = opsSeededState().view
        var pane = try! #require(opsView.panes[opsPaneID])
        pane.content = .terminal
        let terminalView = try! #require(opsView.updatingPane(pane))
        #expect(
            WorkspacePaneRenderPlan.make(view: opsView, columns: 80, rows: 24)
                == WorkspacePaneRenderPlan.make(view: terminalView, columns: 80, rows: 24)
        )
    }
}

@Suite struct WorkspaceOpsPaneModelTests {
    private func ledgerDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ops-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func appendAudit(_ events: [AuditEvent], to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lines = try events.map { try String(decoding: encoder.encode($0), as: UTF8.self) }
        let url = dir.appendingPathComponent("audit.jsonl")
        let text = lines.joined(separator: "\n") + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test func modelSeedsOpsPaneFromLedgerAndPollsAppends() throws {
        let dir = try ledgerDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try appendAudit(
            [opsEvent(seconds: 1, subject: "first"), opsEvent(seconds: 2, subject: "second")],
            to: dir
        )
        let session = FakeWorkspaceSession()
        let shell = WorkspaceTUIModel(
            session: session,
            emulators: RecordingFactory(),
            summary: session.summary,
            launcher: [opsShellChoice],
            opsLedger: AuditLedger(configDirectory: dir)
        )
        try shell.connect().get()
        shell.handle(.control("b"))
        shell.handle(.character("o"))
        var seeded: [String]?
        for _ in 0..<100 {
            if let ops = shell.snapshot().ops.values.first, ops.loaded {
                seeded = ops.events.map(\.subject)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(seeded == ["first", "second"])
        try appendAudit([opsEvent(seconds: 3, subject: "third")], to: dir)
        shell.processPendingWork()
        var polled: [String]?
        for _ in 0..<100 {
            let subjects = shell.snapshot().ops.values.first?.events.map(\.subject)
            if subjects == ["first", "second", "third"] {
                polled = subjects
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(polled == ["first", "second", "third"])
    }

    @Test func modelWithoutLedgerSeedsEmpty() throws {
        let session = FakeWorkspaceSession()
        let shell = WorkspaceTUIModel(
            session: session,
            emulators: RecordingFactory(),
            summary: session.summary,
            launcher: [opsShellChoice]
        )
        try shell.connect().get()
        shell.handle(.control("b"))
        shell.handle(.character("o"))
        var loaded = false
        for _ in 0..<100 {
            if shell.snapshot().ops.values.first?.loaded == true {
                loaded = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(loaded)
        #expect(shell.snapshot().ops.values.first?.events.isEmpty == true)
    }
}

#if os(macOS)
@Suite struct WorkspaceOpsPaneLayoutTests {
    private func layoutFixture() throws -> (root: URL, project: URL, config: URL) {
        let temporary = FileManager.default.temporaryDirectory.path
        guard let canonicalTemporary = realpath(temporary, nil) else {
            throw WorkspaceLayoutStoreError.invalidProject
        }
        defer { free(canonicalTemporary) }
        let root = URL(fileURLWithPath: String(cString: canonicalTemporary))
            .appendingPathComponent("rv-ops-layout-\(UUID().uuidString)")
        let config = root.appendingPathComponent("config")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, project, config)
    }

    @Test func layoutRoundTripPreservesOpsContent() throws {
        let fixture = try layoutFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try WorkspaceLayoutStore.open(
            canonicalOriginalProject: fixture.project.path,
            configurationDirectory: fixture.config
        ).session
        let tabbed = try #require(session.view.addingTab())
        var pane = try #require(tabbed.focusedPane)
        pane.content = .ops
        try session.save(#require(tabbed.updatingPane(pane)))
        let reopened = try WorkspaceLayoutStore.open(
            canonicalOriginalProject: fixture.project.path,
            configurationDirectory: fixture.config
        )
        #expect(reopened.notice == nil)
        #expect(reopened.session.view.focusedPane?.content == .ops)
    }

    @Test func layoutWithoutContentKeyRestoresTerminal() throws {
        let fixture = try layoutFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try WorkspaceLayoutStore.open(
            canonicalOriginalProject: fixture.project.path,
            configurationDirectory: fixture.config
        ).session
        let tabbed = try #require(session.view.addingTab())
        var pane = try #require(tabbed.focusedPane)
        pane.content = .ops
        try session.save(#require(tabbed.updatingPane(pane)))
        let file = session.directoryURL
            .appendingPathComponent("\(session.viewID.rawValue.uuidString).json")
        let saved = try Data(contentsOf: file)
        var object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var panes = try #require(object["panes"] as? [[String: Any]])
        #expect(panes.count == 1)
        #expect(panes[0]["content"] as? String == "ops")
        panes = panes.map { pane in
            var stripped = pane
            stripped.removeValue(forKey: "content")
            return stripped
        }
        object["panes"] = panes
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let reopened = try WorkspaceLayoutStore.open(
            canonicalOriginalProject: fixture.project.path,
            configurationDirectory: fixture.config
        )
        #expect(reopened.notice == nil)
        #expect(reopened.session.view.focusedPane?.content == .terminal)
    }
}
#endif

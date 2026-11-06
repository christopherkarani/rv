import Foundation
import Testing
@testable import RVWorkspaceTUI

// MARK: - Fixtures

private let reviewRuntime = UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!
private let reviewEpoch = Date(timeIntervalSince1970: 1_800_000_000)

private func reviewState(enabled: Bool = true, attached: Bool = true) -> WorkspaceTUIState {
    var state = WorkspaceTUIState(
        lifecycle: .neverConnected,
        summary: WorkspaceTUISummary(project: "/tmp/project", phase: "active", protected: true, workspace: UUID()),
        launcher: [RuntimeLaunchChoice(id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil)],
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
        reviewEnabled: enabled
    )
    state.lifecycle = .connected
    if attached {
        var resize = ResizeCoalescer()
        resize.recordLaunch(rows: 24, columns: 80)
        state.terminal = WorkspaceTUIState.AttachedTerminal(
            state: WorkspaceTerminalState(
                runtime: reviewRuntime, title: "agent", running: true, lease: .owned, subscribed: true
            ),
            resize: resize
        )
    }
    return state
}

private func egress(_ id: String, _ host: String, ageSeconds: TimeInterval) -> ReviewItem {
    ReviewItem(
        id: .egress(id), kind: .pendingEgress, at: reviewEpoch.addingTimeInterval(-ageSeconds),
        summary: "\(host):443", detail: ["proposal \(id)", "  egress \(host):443"]
    )
}

private func block(_ id: String, ageSeconds: TimeInterval) -> ReviewItem {
    ReviewItem(
        id: .block(id), kind: .block, at: reviewEpoch.addingTimeInterval(-ageSeconds),
        summary: "core.git/reset-hard  Bash", detail: ["RV EXPLAIN", "├─ Decision: DENY"]
    )
}

private func reduce(_ state: WorkspaceTUIState, _ events: WorkspaceTUIReducerEvent...) -> WorkspaceTUITransition {
    var last = WorkspaceTUITransition(state: state, effects: [])
    for event in events {
        last = WorkspaceTUIReducer.reduce(last.state, event)
    }
    return last
}

private func press(_ state: WorkspaceTUIState, _ keys: TUIKey...) -> WorkspaceTUITransition {
    var last = WorkspaceTUITransition(state: state, effects: [])
    for key in keys {
        last = WorkspaceTUIReducer.reduce(last.state, .key(key))
    }
    return last
}

/// Opens the pane and lands one load with `items`.
private func openReview(_ items: [ReviewItem], from state: WorkspaceTUIState = reviewState()) -> WorkspaceTUIState {
    let opened = press(state, .control("b"), .character("R"))
    #expect(opened.state.mode == .review)
    #expect(opened.effects == [.loadReview(sequence: 1)])
    return reduce(opened.state, .reviewLoaded(sequence: 1, result: .loaded(items))).state
}

private func isReviewEffect(_ effect: TUIRuntimeEffect) -> Bool {
    switch effect {
    case .approveEgress, .denyEgress, .loadReview: true
    default: false
    }
}

// MARK: - Routing

@Test func reviewRoutingOpensOnlyFromPrefix() {
    let target = PrefixTarget(pane: PaneID(), generation: nil)
    #expect(CommandPrefix.route(.character("R"), mode: .prefix(target), launcher: []) == (.review, .enterReview))
    // In terminal mode every review key is runtime input.
    for key: TUIKey in [.character("R"), .character("a"), .character("d"), .character("y"), .enter] {
        #expect(CommandPrefix.route(key, mode: .terminal, launcher: []) == (.terminal, .sendKey(key)))
    }
}

@Test func reviewRoutingNavigatesActsAndCloses() {
    #expect(CommandPrefix.route(.character("j"), mode: .review, launcher: []) == (.review, .reviewMove(delta: 1)))
    #expect(CommandPrefix.route(.arrow(.down), mode: .review, launcher: []) == (.review, .reviewMove(delta: 1)))
    #expect(CommandPrefix.route(.character("k"), mode: .review, launcher: []) == (.review, .reviewMove(delta: -1)))
    #expect(CommandPrefix.route(.arrow(.up), mode: .review, launcher: []) == (.review, .reviewMove(delta: -1)))
    #expect(CommandPrefix.route(.character("g"), mode: .review, launcher: []) == (.review, .reviewTop))
    #expect(CommandPrefix.route(.character("G"), mode: .review, launcher: []) == (.review, .reviewBottom))
    #expect(CommandPrefix.route(.character("a"), mode: .review, launcher: []) == (.review, .reviewApprove))
    #expect(CommandPrefix.route(.character("d"), mode: .review, launcher: []) == (.review, .reviewDenyStart))
    #expect(CommandPrefix.route(.character("A"), mode: .review, launcher: []) == (.review, nil))
    #expect(CommandPrefix.route(.enter, mode: .review, launcher: []) == (.review, nil))
    #expect(CommandPrefix.route(.escape, mode: .review, launcher: []) == (.terminal, .exitReview))
    #expect(CommandPrefix.route(.character("q"), mode: .review, launcher: []) == (.terminal, .exitReview))
}

@Test func denyReasonRoutingEditsSubmitsAndBacksOut() {
    let mode = CommandMode.reviewDenyReason(id: "p1", input: "trac")
    #expect(CommandPrefix.route(.character("k"), mode: mode, launcher: [])
        == (.reviewDenyReason(id: "p1", input: "track"), nil))
    #expect(CommandPrefix.route(.backspace, mode: mode, launcher: [])
        == (.reviewDenyReason(id: "p1", input: "tra"), nil))
    #expect(CommandPrefix.route(.enter, mode: mode, launcher: [])
        == (.review, .reviewDenySubmit(id: "p1", reason: "trac")))
    #expect(CommandPrefix.route(.escape, mode: mode, launcher: []) == (.review, nil))
    let full = CommandMode.reviewDenyReason(id: "p1", input: String(repeating: "x", count: 500))
    #expect(CommandPrefix.route(.character("y"), mode: full, launcher: []) == (full, nil))
}

// MARK: - Runtime keystrokes never reach review actions

@Suite struct ReviewRuntimeIsolationTests {
    @Test func keysTypedIntoRuntimeOnlyBecomeRuntimeInput() {
        let state = reviewState()
        for key: TUIKey in [.character("a"), .character("d"), .character("R"), .character("y"), .enter] {
            let transition = press(state, key)
            #expect(transition.state.mode == .terminal)
            #expect(transition.effects.contains(where: isReviewEffect) == false)
            #expect(transition.effects == [.queueKey(binding: state.activeBindingKey!, key: key)])
        }
    }

    @Test func runtimeOutputCannotOpenOrDriveReview() {
        // Ctrl-B R a d y, as bytes the agent writes to its own PTY.
        let hostile = Data([0x02]) + Data("Rady\r".utf8)
        let state = openReview([egress("p1", "evil.example.com", ageSeconds: 5)])
        var terminalState = state
        terminalState.mode = .terminal
        for base in [terminalState, state] {
            let fed = reduce(base, .hostEvents([.bytes(runtime: reviewRuntime, data: hostile)]))
            #expect(fed.effects.contains(where: isReviewEffect) == false)
            #expect(fed.state.mode == base.mode)
            #expect(fed.state.review.action == nil)
            let replied = reduce(base, .emulatorResponded(
                binding: base.activeBindingKey!, responses: [hostile]
            ))
            #expect(replied.effects.contains(where: isReviewEffect) == false)
            #expect(replied.state.review.action == nil)
        }
    }

    @Test func pasteNeverReachesReviewActions() {
        let hostile = "\u{02}Ra"
        let base = reviewState()
        let terminal = reduce(base, .paste(hostile))
        #expect(terminal.effects == [.queuePaste(binding: base.activeBindingKey!, text: hostile)])
        let open = openReview([egress("p1", "api.example.com", ageSeconds: 5)])
        let pasted = reduce(open, .paste("a"))
        #expect(pasted.effects.isEmpty)
        #expect(pasted.state.review.action == nil)
        var denying = open
        denying.mode = .reviewDenyReason(id: "p1", input: "")
        #expect(reduce(denying, .paste("x\r")).state.mode == .reviewDenyReason(id: "p1", input: ""))
    }

    @Test func reviewKeysNeverReachTheRuntime() {
        let open = openReview([egress("p1", "api.example.com", ageSeconds: 5)])
        for key: TUIKey in [.character("j"), .character("x"), .enter, .character("z")] {
            let transition = press(open, key)
            #expect(transition.effects.allSatisfy { effect in
                if case .queueKey = effect { return false }
                return true
            })
        }
    }
}

// MARK: - Reducer

@Suite struct ReviewReducerTests {
    @Test func openingWithoutSourceRefuses() {
        let transition = press(reviewState(enabled: false), .control("b"), .character("R"))
        #expect(transition.state.mode == .terminal)
        #expect(transition.state.feedback == "Review is unavailable")
        #expect(transition.effects.isEmpty)
    }

    @Test func disabledReviewNeverPolls() {
        let transition = reduce(reviewState(enabled: false), .tick(now: reviewEpoch))
        #expect(transition.effects.contains(where: isReviewEffect) == false)
    }

    @Test func tickPollsOnCadenceAndNeverOverlaps() {
        let first = reduce(reviewState(), .tick(now: reviewEpoch))
        #expect(first.effects.contains(.loadReview(sequence: 1)))
        // In flight: no second read even once the cadence is due again.
        let waiting = reduce(first.state, .tick(now: reviewEpoch.addingTimeInterval(5)))
        #expect(waiting.effects.contains(where: isReviewEffect) == false)
        let landed = reduce(waiting.state, .reviewLoaded(sequence: 1, result: .loaded([])))
        let early = reduce(landed.state, .tick(now: reviewEpoch.addingTimeInterval(1)))
        #expect(early.effects.contains(where: isReviewEffect) == false)
        let due = reduce(landed.state, .tick(now: reviewEpoch.addingTimeInterval(1.5)))
        #expect(due.effects.contains(.loadReview(sequence: 2)))
    }

    @Test func pollKeepsRunningWhileHostDisconnected() {
        var state = reviewState()
        state.lifecycle = .disconnected
        state.reconnectAttempt = 0
        let transition = reduce(state, .tick(now: reviewEpoch))
        #expect(transition.effects.contains(.loadReview(sequence: 1)))
    }

    @Test func loadSortsNewestFirstAndCountsPending() {
        let state = openReview([
            block("b1", ageSeconds: 300), egress("p1", "a.example.com", ageSeconds: 60),
            egress("p2", "b.example.com", ageSeconds: 10),
        ])
        #expect(state.review.items.map(\.id) == [.egress("p2"), .egress("p1"), .block("b1")])
        #expect(state.review.pendingCount == 2)
        #expect(state.review.selected == .egress("p2"))
    }

    @Test func selectionFollowsIdAcrossRefresh() {
        var state = openReview([egress("p1", "a.example.com", ageSeconds: 60), block("b1", ageSeconds: 300)])
        state = press(state, .character("j")).state
        #expect(state.review.selected == .block("b1"))
        // A newer row arrives on top; the selection stays on b1.
        let refreshed = reduce(
            state, .tick(now: reviewEpoch.addingTimeInterval(10)),
            .reviewLoaded(sequence: 2, result: .loaded([
                egress("p9", "new.example.com", ageSeconds: 1),
                egress("p1", "a.example.com", ageSeconds: 60), block("b1", ageSeconds: 300),
            ]))
        )
        #expect(refreshed.state.review.selected == .block("b1"))
    }

    @Test func vanishedSelectionFallsToSamePosition() {
        var state = openReview([
            egress("p1", "a.example.com", ageSeconds: 10), egress("p2", "b.example.com", ageSeconds: 20),
            block("b1", ageSeconds: 30),
        ])
        state = press(state, .character("j")).state
        #expect(state.review.selected == .egress("p2"))
        let refreshed = reduce(
            state, .tick(now: reviewEpoch.addingTimeInterval(10)),
            .reviewLoaded(sequence: 2, result: .loaded([
                egress("p1", "a.example.com", ageSeconds: 10), block("b1", ageSeconds: 30),
            ]))
        )
        #expect(refreshed.state.review.selected == .block("b1"))
    }

    @Test func navigationClampsAndJumps() {
        var state = openReview([
            egress("p1", "a.example.com", ageSeconds: 10), block("b1", ageSeconds: 20), block("b2", ageSeconds: 30),
        ])
        state = press(state, .character("k")).state
        #expect(state.review.selected == .egress("p1"))
        state = press(state, .character("G")).state
        #expect(state.review.selected == .block("b2"))
        state = press(state, .character("j")).state
        #expect(state.review.selected == .block("b2"))
        state = press(state, .character("g")).state
        #expect(state.review.selected == .egress("p1"))
    }

    @Test func staleLoadNeverLands() {
        let state = openReview([egress("p1", "a.example.com", ageSeconds: 10)])
        let stale = reduce(state, .reviewLoaded(sequence: 1, result: .loaded([])))
        #expect(stale.state.review.items.count == 1)
    }

    @Test func loadFailureShowsErrorAndOffersNoActions() {
        let opened = press(reviewState(), .control("b"), .character("R"))
        let failed = reduce(opened.state, .reviewLoaded(sequence: 1, result: .failed("egress store unavailable")))
        #expect(failed.state.review.load == .failed("egress store unavailable"))
        #expect(failed.state.review.selected == nil)
        let approve = press(failed.state, .character("a"))
        #expect(approve.effects.isEmpty)
        #expect(approve.state.review.action == nil)
        #expect(approve.state.review.notice?.isError == true)
        // A failure after a good load also drops the rows (fail closed).
        let good = openReview([egress("p1", "a.example.com", ageSeconds: 10)])
        let dropped = reduce(
            good, .tick(now: reviewEpoch.addingTimeInterval(10)),
            .reviewLoaded(sequence: 2, result: .failed("egress store unavailable"))
        )
        #expect(dropped.state.review.items.isEmpty)
        #expect(press(dropped.state, .character("a")).effects.isEmpty)
    }

    @Test func approveStartsOneCeremonyAndNeverEditsRows() {
        let state = openReview([egress("p1", "api.example.com", ageSeconds: 10)])
        let approving = press(state, .character("a"))
        #expect(approving.effects == [.approveEgress(id: "p1")])
        #expect(approving.state.review.action == .approving("p1"))
        // No approve-all, no second ceremony while one runs.
        let again = press(approving.state, .character("a"))
        #expect(again.effects.isEmpty)
        let completed = reduce(approving.state, .reviewActionCompleted(
            id: "p1", outcome: .completed("approved api.example.com:443")
        ))
        #expect(completed.state.review.action == nil)
        #expect(completed.state.review.notice == .init(text: "approved api.example.com:443", isError: false))
        // The row is untouched until the forced re-read lands.
        #expect(completed.state.review.items == state.review.items)
        #expect(completed.effects == [.loadReview(sequence: 2)])
        let reread = reduce(completed.state, .reviewLoaded(sequence: 2, result: .loaded([])))
        #expect(reread.state.review.items.isEmpty)
    }

    @Test func refusedApproveKeepsRowAndRereads() {
        let state = openReview([egress("p1", "api.example.com", ageSeconds: 10)])
        let approving = press(state, .character("a"))
        let refused = reduce(approving.state, .reviewActionCompleted(
            id: "p1", outcome: .refused("approve refused: device-owner authentication required")
        ))
        #expect(refused.state.review.notice?.isError == true)
        #expect(refused.state.review.items == state.review.items)
        #expect(refused.effects == [.loadReview(sequence: 2)])
    }

    @Test func approveSupersedesInflightPoll() {
        let state = openReview([egress("p1", "api.example.com", ageSeconds: 10)])
        let polling = reduce(state, .tick(now: reviewEpoch.addingTimeInterval(10)))
        #expect(polling.effects.contains(.loadReview(sequence: 2)))
        let approving = press(polling.state, .character("a"))
        let completed = reduce(approving.state, .reviewActionCompleted(id: "p1", outcome: .completed("approved")))
        #expect(completed.effects == [.loadReview(sequence: 3)])
        // The pre-approve poll result is stale and must not land.
        let stale = reduce(completed.state, .reviewLoaded(
            sequence: 2, result: .loaded([egress("p1", "api.example.com", ageSeconds: 10)])
        ))
        #expect(stale.state.review.inflightLoad == 3)
        let fresh = reduce(stale.state, .reviewLoaded(sequence: 3, result: .loaded([])))
        #expect(fresh.state.review.items.isEmpty)
    }

    @Test func blocksOfferNoActions() {
        let state = openReview([block("b1", ageSeconds: 10)])
        #expect(press(state, .character("a")).effects.isEmpty)
        let deny = press(state, .character("d"))
        #expect(deny.effects.isEmpty)
        #expect(deny.state.mode == .review)
        #expect(deny.state.review.notice?.text == "Select a pending egress proposal to deny")
    }

    @Test func denyAsksForReasonAndTargetsCapturedProposal() {
        var state = openReview([egress("p1", "a.example.com", ageSeconds: 10), block("b1", ageSeconds: 20)])
        state = press(state, .character("d")).state
        #expect(state.mode == .reviewDenyReason(id: "p1", input: ""))
        // Empty reason: stays in the prompt, no ceremony.
        let empty = press(state, .character(" "), .enter)
        #expect(empty.effects.isEmpty)
        #expect(empty.state.mode == .reviewDenyReason(id: "p1", input: " "))
        #expect(empty.state.review.notice?.text == "A reason is required to deny")
        // A refresh that moves the selection cannot retarget the deny.
        let moved = reduce(
            state, .tick(now: reviewEpoch.addingTimeInterval(10)),
            .reviewLoaded(sequence: 2, result: .loaded([
                egress("p0", "z.example.com", ageSeconds: 1),
                egress("p1", "a.example.com", ageSeconds: 10), block("b1", ageSeconds: 20),
            ]))
        ).state
        let submitted = press(moved, .character("n"), .character("o"), .enter)
        #expect(submitted.effects == [.denyEgress(id: "p1", reason: "no")])
        #expect(submitted.state.review.action == .denying("p1"))
        #expect(submitted.state.mode == .review)
        // Esc backs out of the prompt without a ceremony.
        let backed = press(state, .character("x"), .escape)
        #expect(backed.state.mode == .review)
        #expect(backed.effects.isEmpty)
    }

    @Test func denyRefusesWhenProposalLeftTheQueue() {
        var state = openReview([egress("p1", "a.example.com", ageSeconds: 10)])
        state = press(state, .character("d")).state
        state = reduce(
            state, .tick(now: reviewEpoch.addingTimeInterval(10)),
            .reviewLoaded(sequence: 2, result: .loaded([]))
        ).state
        let submitted = press(state, .character("n"), .enter)
        #expect(submitted.effects.isEmpty)
        #expect(submitted.state.review.notice?.text == "Proposal is no longer pending")
    }

    @Test func completionAfterDetachIsIgnored() {
        let state = openReview([egress("p1", "a.example.com", ageSeconds: 10)])
        let approving = press(state, .character("a")).state
        let detached = reduce(approving, .detachRequested).state
        let late = reduce(detached, .reviewActionCompleted(id: "p1", outcome: .completed("approved")))
        #expect(late.effects.contains(where: isReviewEffect) == false)
    }
}

// MARK: - Text

@Suite struct ReviewTextTests {
    @Test func goldenPaneWithPendingSelected() {
        let state = openReview([egress("p1", "api.example.com", ageSeconds: 120), block("b1", ageSeconds: 300)])
        #expect(WorkspaceReviewText.lines(state.review, mode: state.mode, now: reviewEpoch) == [
            "REVIEW  1 pending · 1 block",
            "> egress  api.example.com:443 · 2m",
            "  block   core.git/reset-hard  Bash · 5m",
            "",
            "proposal p1",
            "  egress api.example.com:443",
            "",
            "a approve · d deny · j/k move · g/G first/last · Esc close",
        ])
    }

    @Test func goldenPaneWithBlockSelectedOffersNoActions() {
        let state = press(openReview([egress("p1", "api.example.com", ageSeconds: 120), block("b1", ageSeconds: 300)]),
                          .character("j")).state
        #expect(WorkspaceReviewText.lines(state.review, mode: state.mode, now: reviewEpoch) == [
            "REVIEW  1 pending · 1 block",
            "  egress  api.example.com:443 · 2m",
            "> block   core.git/reset-hard  Bash · 5m",
            "",
            "RV EXPLAIN",
            "├─ Decision: DENY",
            "",
            "j/k move · g/G first/last · Esc close",
        ])
    }

    @Test func goldenDenyPromptAndBusyHints() {
        var state = openReview([egress("p1", "api.example.com", ageSeconds: 5)])
        state = press(state, .character("d"), .character("n"), .character("o")).state
        let lines = WorkspaceReviewText.lines(state.review, mode: state.mode, now: reviewEpoch)
        #expect(Array(lines.suffix(2)) == ["Deny reason: no", "Enter deny · Esc back"])
        let busy = press(state, .enter).state
        #expect(WorkspaceReviewText.hint(busy.review, mode: busy.mode) == "j/k move · g/G first/last · Esc close")
        #expect(WorkspaceReviewText.lines(busy.review, mode: busy.mode, now: reviewEpoch).suffix(2) == [
            "Denying api.example.com:443: authenticate to continue",
            "j/k move · g/G first/last · Esc close",
        ])
    }

    @Test func goldenLoadingFailedAndEmpty() {
        let opened = press(reviewState(), .control("b"), .character("R")).state
        #expect(WorkspaceReviewText.lines(opened.review, mode: opened.mode, now: reviewEpoch)
            == ["REVIEW", "Loading review queue…", "", "Esc close"])
        let failed = reduce(opened, .reviewLoaded(sequence: 1, result: .failed("egress store unavailable"))).state
        #expect(WorkspaceReviewText.lines(failed.review, mode: failed.mode, now: reviewEpoch)
            == ["REVIEW", "Review unavailable: egress store unavailable", "", "Esc close"])
        let empty = reduce(opened, .reviewLoaded(sequence: 1, result: .loaded([]))).state
        #expect(WorkspaceReviewText.lines(empty.review, mode: empty.mode, now: reviewEpoch)
            == ["REVIEW  0 pending · 0 blocks", "Nothing to review.", "", "Esc close"])
    }

    @Test func untrustedTextCannotPaintTheTerminal() {
        let spoof = ReviewItem(
            id: .block("b1"), kind: .block, at: reviewEpoch,
            summary: "x\u{1b}[2K\rapproved\u{202E}", detail: ["\u{1b}]0;title\u{07}line"]
        )
        let state = openReview([spoof])
        let text = WorkspaceReviewText.lines(state.review, mode: state.mode, now: reviewEpoch).joined()
        #expect(text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0.value == 0x202E } == false)
    }

    @Test func listWindowKeepsSelectionVisible() {
        let items = (0..<20).map { block("b\($0)", ageSeconds: TimeInterval($0)) }
        let state = press(openReview(items), .character("G")).state
        let rows = WorkspaceReviewText.lines(state.review, mode: state.mode, now: reviewEpoch)
            .filter { $0.hasPrefix("> ") || $0.hasPrefix("  block") }
        #expect(rows.count == WorkspaceReviewText.listRows)
        #expect(rows.last?.hasPrefix("> ") == true)
    }

    @Test func badgeShowsOnlyPendingCount() {
        #expect(WorkspaceReviewText.badge(openReview([block("b1", ageSeconds: 1)]).review) == nil)
        let pending = openReview([egress("p1", "a.example.com", ageSeconds: 1), egress("p2", "b.example.com", ageSeconds: 2)])
        #expect(WorkspaceReviewText.badge(pending.review) == "2 pending · Ctrl-B R")
    }
}

// MARK: - Model runtime

private final class FakeReviewSource: ReviewQueueSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ReviewItem]
    private var calls: [String] = []

    init(_ items: [ReviewItem]) { queue = items }

    var recorded: [String] { lock.withLock { calls } }

    func load(now: Date) async -> ReviewLoadResult {
        lock.withLock {
            calls.append("load")
            return .loaded(queue)
        }
    }

    func approve(egress id: String) async -> ReviewActionOutcome {
        lock.withLock {
            calls.append("approve \(id)")
            queue.removeAll { $0.id == .egress(id) }
            return .completed("approved \(id)")
        }
    }

    func deny(egress id: String, reason: String) async -> ReviewActionOutcome {
        lock.withLock {
            calls.append("deny \(id) \(reason)")
            return .refused("deny refused: store unavailable")
        }
    }
}

@Test func modelApproveRunsSourceOnceThenRereadsStore() {
    let source = FakeReviewSource([egress("p1", "api.example.com", ageSeconds: 5), block("b1", ageSeconds: 9)])
    let model = WorkspaceTUIModel(
        session: FakeWorkspaceSession(),
        summary: WorkspaceTUISummary(project: "/tmp/project", phase: "active", protected: true, workspace: UUID()),
        launcher: [],
        review: source
    )
    model.handle(.control("b"))
    model.handle(.character("R"))
    model.waitForReviewWork()
    #expect(model.snapshot().review.pendingCount == 1)
    model.handle(.character("a"))
    model.waitForReviewWork()
    #expect(source.recorded == ["load", "approve p1", "load"])
    let review = model.snapshot().review
    #expect(review.items.map(\.id) == [.block("b1")])
    #expect(review.notice?.text == "approved p1")
    #expect(review.action == nil)
}

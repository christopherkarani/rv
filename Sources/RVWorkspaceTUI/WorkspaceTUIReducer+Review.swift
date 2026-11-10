import Foundation

// Review pane transitions: polling, loads, selection, approve and deny.
//
// Safety shape: an approve or deny is only ever emitted from a key routed
// in `.review` / `.reviewDenyReason`, which only Ctrl-B R opens. Runtime
// output, emulator replies, and keys typed in terminal mode have no path
// here. The effect only starts the CLI's owner-authenticated ceremony;
// its result sets a notice and forces a re-read, never a row edit.
extension WorkspaceTUIReducer {
    /// Issues a poll when none is in flight and the cadence is due. A read
    /// in flight past `loadTimeout` marks the pane stale and is superseded
    /// by a fresh one; the hung read's late result fails the sequence check.
    static func tickReview(
        now: Date,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.review.enabled, next.shouldExit == false else { return }
        next.review.lastTickAt = now
        if next.review.inflightLoad != nil {
            // Loads issued from keys or completions carry no clock: the
            // first tick that sees them stamps their start.
            let since = next.review.inflightSince ?? now
            next.review.inflightSince = since
            guard now.timeIntervalSince(since) > WorkspaceReviewState.loadTimeout else { return }
            if next.review.stale == false {
                next.review.stale = true
                presentationChanged = true
            }
        } else if let due = next.review.nextPollAt, now < due {
            return
        }
        next.review.nextPollAt = now.addingTimeInterval(WorkspaceReviewState.pollInterval)
        issueReviewLoad(to: &next, effects: &effects)
    }

    /// Supersedes any in-flight read: its result will no longer land.
    private static func issueReviewLoad(to next: inout WorkspaceTUIState, effects: inout [TUIRuntimeEffect]) {
        next.review.loadSequence &+= 1
        next.review.inflightLoad = next.review.loadSequence
        next.review.inflightSince = next.review.lastTickAt
        effects.append(.loadReview(sequence: next.review.loadSequence))
    }

    static func reduceReviewLoaded(
        sequence: UInt64,
        result: ReviewLoadResult,
        to next: inout WorkspaceTUIState,
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle != .detached, next.review.inflightLoad == sequence else { return }
        let issuedAt = next.review.inflightSince ?? next.review.lastTickAt
        let settled = next.review.settled
        let wasStale = next.review.stale
        next.review.inflightLoad = nil
        next.review.inflightSince = nil
        next.review.settled = nil
        next.review.stale = false
        let before = next.review
        switch result {
        case .failed(let message):
            // Fail closed: no rows, so nothing is selectable or actionable.
            next.review.load = .failed(message)
            next.review.selected = nil
            next.review.selectionConfirmed = true
        case .loaded(let items):
            let sorted = items.sorted(by: reviewOrder)
            next.review.load = .loaded(sorted)
            if let selected = before.selected, sorted.contains(where: { $0.id == selected }) == false {
                fallBack(from: selected, before: before, sorted: sorted, settled: settled, to: &next)
            } else if before.selected == nil {
                next.review.selected = sorted.first?.id
            }
        }
        // Freshness alone is not a repaint: the timestamp is read at render.
        if wasStale || next.review != before {
            presentationChanged = true
        }
        next.review.lastUpdatedAt = issuedAt
    }

    /// The selected row vanished. The cursor keeps its position for
    /// navigation, but the selection is unconfirmed: approve and deny wait
    /// for the user to move, so a refresh never retargets a keypress.
    private static func fallBack(
        from selected: ReviewItemID,
        before: WorkspaceReviewState,
        sorted: [ReviewItem],
        settled: ReviewItemID?,
        to next: inout WorkspaceTUIState
    ) {
        let previousIndex = before.items.firstIndex { $0.id == selected } ?? 0
        next.review.selected = sorted.isEmpty ? nil : sorted[min(previousIndex, sorted.count - 1)].id
        next.review.selectionConfirmed = false
        // Our own approve or deny already explained why the row left.
        if selected != settled {
            next.review.notice = .init(text: "Selected item resolved elsewhere", isError: false)
        }
    }

    static func reduceReviewActionCompleted(
        id: String,
        outcome: ReviewActionOutcome,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle != .detached, next.review.action?.id == id else { return }
        next.review.action = nil
        switch outcome {
        case .completed(let text):
            next.review.notice = .init(text: text, isError: false)
            next.review.settled = .egress(id)
        case .refused(let text):
            next.review.notice = .init(text: text, isError: true)
        }
        // Never trust the outcome for row state: re-read the store.
        issueReviewLoad(to: &next, effects: &effects)
        presentationChanged = true
    }

    static func applyReviewCommand(
        _ command: TUICommand,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch command {
        case .enterReview:
            guard next.review.enabled else {
                next.mode = .terminal
                next.feedback = "Review is unavailable"
                next.feedbackTicks = 60
                presentationChanged = true
                return
            }
            // A freshly opened pane has not been measured yet.
            next.review.paneSize = nil
            if next.review.inflightLoad == nil {
                issueReviewLoad(to: &next, effects: &effects)
            }
        case .reviewMove(let delta):
            moveReviewSelection(to: &next) { index, _ in index + delta }
        case .reviewTop:
            moveReviewSelection(to: &next) { _, _ in 0 }
        case .reviewBottom:
            moveReviewSelection(to: &next) { _, count in count - 1 }
        case .reviewApprove:
            // The owner must see what they approve: the same check that
            // makes the pane show `tooSmall` refuses the approve.
            let now = next.review.lastTickAt ?? .distantPast
            guard WorkspaceReviewText.showsWholeReview(next.review, mode: next.mode, now: now) else {
                next.review.notice = .init(text: tooSmallRefusal, isError: true)
                break
            }
            guard let id = actionableEgress(in: &next, verb: "approve") else { break }
            let summary = next.review.selectedItem?.summary ?? id
            next.review.action = .approving(id)
            next.review.notice = .init(text: "Approving \(summary): authenticate to continue", isError: false)
            effects.append(.approveEgress(id: id))
        case .reviewDenyStart:
            guard let id = actionableEgress(in: &next, verb: "deny") else { break }
            next.mode = .reviewDenyReason(id: id, input: "")
        case .reviewDenySubmit(let id, let reason):
            submitDeny(id: id, reason: reason, to: &next, effects: &effects)
        case .exitReview:
            break
        default:
            return
        }
        presentationChanged = true
    }

    /// The selected row's proposal id when an action may start; otherwise
    /// sets a notice and returns nil.
    private static func actionableEgress(in next: inout WorkspaceTUIState, verb: String) -> String? {
        guard next.review.action == nil else {
            next.review.notice = .init(text: "Another review action is in progress", isError: true)
            return nil
        }
        if let refusal = reviewActionRefusal(next.review) {
            next.review.notice = .init(text: refusal, isError: true)
            return nil
        }
        guard let item = next.review.selectedItem, item.kind == .pendingEgress,
              case .egress(let id) = item.id else {
            next.review.notice = .init(text: "Select a pending egress proposal to \(verb)", isError: true)
            return nil
        }
        return id
    }

    private static func submitDeny(
        id: String,
        reason: String,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect]
    ) {
        guard reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            next.mode = .reviewDenyReason(id: id, input: reason)
            next.review.notice = .init(text: "A reason is required to deny", isError: true)
            return
        }
        guard next.review.action == nil else {
            next.review.notice = .init(text: "Another review action is in progress", isError: true)
            return
        }
        guard next.review.stale == false else {
            next.mode = .reviewDenyReason(id: id, input: reason)
            next.review.notice = .init(text: staleRefusal, isError: true)
            return
        }
        guard let item = next.review.items.first(where: { $0.id == .egress(id) }),
              item.kind == .pendingEgress else {
            next.review.notice = .init(text: "Proposal is no longer pending", isError: true)
            return
        }
        next.review.action = .denying(id)
        next.review.notice = .init(text: "Denying \(item.summary): authenticate to continue", isError: false)
        effects.append(.denyEgress(id: id, reason: reason))
    }

    private static let staleRefusal = "Review is stale: wait for a fresh read"
    private static let tooSmallRefusal = "Terminal too small to review safely: enlarge it to approve"

    /// Why approve/deny may not start on the selected row, if anything.
    private static func reviewActionRefusal(_ review: WorkspaceReviewState) -> String? {
        if review.stale { return staleRefusal }
        if review.selectionConfirmed == false { return "Selected item resolved elsewhere: move to confirm a row" }
        return nil
    }

    private static func moveReviewSelection(
        to next: inout WorkspaceTUIState,
        _ target: (_ index: Int, _ count: Int) -> Int
    ) {
        let items = next.review.items
        guard items.isEmpty == false else { return }
        let current = next.review.selected.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let index = min(max(0, target(current, items.count)), items.count - 1)
        next.review.selected = items[index].id
        next.review.selectionConfirmed = true
    }

    /// Newest first; ties break deterministically (pending before blocks,
    /// then by id) so equal timestamps never reorder between polls.
    private static func reviewOrder(_ left: ReviewItem, _ right: ReviewItem) -> Bool {
        if left.at != right.at { return left.at > right.at }
        return reviewTieKey(left) < reviewTieKey(right)
    }

    private static func reviewTieKey(_ item: ReviewItem) -> String {
        switch item.id {
        case .egress(let id): "0\(id)"
        case .block(let id): "1\(id)"
        }
    }
}

import Foundation

// Review pane transitions: polling, loads, selection, approve and deny.
//
// Safety shape: an approve or deny is only ever emitted from a key routed
// in `.review` / `.reviewDenyReason`, which only Ctrl-B R opens. Runtime
// output, emulator replies, and keys typed in terminal mode have no path
// here. The effect only starts the CLI's owner-authenticated ceremony;
// its result sets a notice and forces a re-read, never a row edit.
extension WorkspaceTUIReducer {
    /// Issues a poll when none is in flight and the cadence is due.
    static func tickReview(now: Date, to next: inout WorkspaceTUIState, effects: inout [TUIRuntimeEffect]) {
        guard next.review.enabled, next.shouldExit == false, next.review.inflightLoad == nil else { return }
        if let due = next.review.nextPollAt, now < due { return }
        next.review.nextPollAt = now.addingTimeInterval(WorkspaceReviewState.pollInterval)
        issueReviewLoad(to: &next, effects: &effects)
    }

    /// Supersedes any in-flight read: its result will no longer land.
    private static func issueReviewLoad(to next: inout WorkspaceTUIState, effects: inout [TUIRuntimeEffect]) {
        next.review.loadSequence &+= 1
        next.review.inflightLoad = next.review.loadSequence
        effects.append(.loadReview(sequence: next.review.loadSequence))
    }

    static func reduceReviewLoaded(
        sequence: UInt64,
        result: ReviewLoadResult,
        to next: inout WorkspaceTUIState,
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle != .detached, next.review.inflightLoad == sequence else { return }
        next.review.inflightLoad = nil
        let before = next.review
        switch result {
        case .failed(let message):
            // Fail closed: no rows, so nothing is selectable or actionable.
            next.review.load = .failed(message)
            next.review.selected = nil
        case .loaded(let items):
            let sorted = items.sorted(by: reviewOrder)
            let previousIndex = before.selected.flatMap { id in before.items.firstIndex { $0.id == id } }
            next.review.load = .loaded(sorted)
            if let selected = before.selected, sorted.contains(where: { $0.id == selected }) {
                next.review.selected = selected
            } else if sorted.isEmpty {
                next.review.selected = nil
            } else {
                next.review.selected = sorted[min(previousIndex ?? 0, sorted.count - 1)].id
            }
        }
        if next.review != before {
            presentationChanged = true
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
            guard let id = actionableEgress(in: &next, verb: "approve") else { break }
            let summary = next.review.selectedItem?.summary ?? id
            next.review.action = .approving(id)
            next.review.notice = .init(text: "Approving \(summary): authenticate to continue", isError: false)
            effects = [.approveEgress(id: id)]
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
        guard let item = next.review.items.first(where: { $0.id == .egress(id) }),
              item.kind == .pendingEgress else {
            next.review.notice = .init(text: "Proposal is no longer pending", isError: true)
            return
        }
        next.review.action = .denying(id)
        next.review.notice = .init(text: "Denying \(item.summary): authenticate to continue", isError: false)
        effects = [.denyEgress(id: id, reason: reason)]
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

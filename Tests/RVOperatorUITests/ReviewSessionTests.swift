import Foundation
import RVIPC
import Testing

@testable import RVOperatorUI

private func launchBundle(_ item: UIReviewItemDTO, challenge: UUID = UUID()) -> UIChallengeBundleDTO {
    UIChallengeBundleDTO(
        challenge: UIChallengeDTO(
            challengeID: challenge, operationID: item.operationID,
            intentDigestHex: item.intentDigestHex, kind: item.kind,
            uiConnectionID: UUID(), issuedWall: Date(), advisoryLifetimeSeconds: 120),
        item: item)
}

private func actionBundle(_ item: UIActionReviewItemDTO) -> UIActionChallengeBundleDTO {
    UIActionChallengeBundleDTO(
        challenge: UIActionChallengeDTO(
            challengeID: UUID(), approvalID: item.approvalID,
            actionDigestHex: item.actionDigestHex, uiConnectionID: UUID(),
            issuedWall: Date(), advisoryLifetimeSeconds: 300),
        item: item)
}

private func hookBundle(_ item: UIHookReviewItemDTO) -> UIHookChallengeBundleDTO {
    UIHookChallengeBundleDTO(
        challenge: UIHookChallengeDTO(
            challengeID: UUID(), approvalID: item.approvalID,
            actionFingerprint: item.actionFingerprint, uiConnectionID: UUID(),
            issuedWall: Date(), advisoryLifetimeSeconds: 300),
        item: item)
}

/// Drives a session synchronously and asserts SEC-001 after every event.
private struct Script<Mode: ReviewMode> {
    var session = ReviewSession<Mode>()

    @discardableResult
    mutating func send(_ event: ReviewSession<Mode>.Event) -> [ReviewSession<Mode>.Command] {
        let commands = session.reduce(event)
        #expect(session.selectionInvariantHolds)
        return commands
    }

    /// Connects and lists `items`; leaves the session `.connected`.
    mutating func connect(items: [Mode.Item]) {
        send(.connectRequested)
        let commands = send(.connectReplied(nil))
        guard case .list(let gen)? = commands.first else {
            Issue.record("connect did not request a list")
            return
        }
        send(.listReplied(gen: gen, .success(items)))
    }

    /// Selects `id`, returns the bind ticket.
    mutating func select(_ id: Mode.ID) -> Int {
        let commands = send(.selectTapped(id))
        guard case .bind(_, let ticket)? = commands.first else {
            Issue.record("select did not bind")
            return -1
        }
        return ticket
    }
}

private typealias Launch = Script<LaunchReview>

@Suite("Review session reducer")
struct ReviewSessionTests {
    // MARK: Selection transitions

    @Test func connectThenListLoadsItems() {
        let item = reviewItem()
        var s = Launch()
        #expect(s.send(.connectRequested) == [.connect])
        #expect(s.session.connection == .connecting)
        #expect(s.send(.connectRequested).isEmpty)
        #expect(s.send(.connectReplied(nil)) == [.list(gen: 1)])
        s.send(.listReplied(gen: 1, .success([item])))
        #expect(s.session.connection == .connected)
        #expect(s.session.items == [item])
        #expect(s.send(.connectRequested).isEmpty)
    }

    @Test func connectFailureIsRecordedAndRetryable() {
        var s = Launch()
        s.send(.connectRequested)
        s.send(.connectReplied(ReviewFailure(message: "Lost connection to rvd.")))
        #expect(s.session.connection == .failed("Lost connection to rvd."))
        #expect(s.send(.connectRequested) == [.connect])
    }

    @Test func noneToBindingToBound() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        let ticket = s.select(item.operationID)
        #expect(s.session.selection == .binding(item.operationID))
        let bundle = launchBundle(item)
        s.send(.bindReplied(item.operationID, ticket: ticket, .success(bundle)))
        #expect(s.session.selection == .bound(bundle))
        #expect(s.session.bound == bundle)
    }

    @Test func bindFailureLeavesUnboundWithNotice() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        let ticket = s.select(item.operationID)
        s.send(.bindReplied(item.operationID, ticket: ticket,
            .failure(ReviewFailure(message: "Request failed."))))
        #expect(s.session.selection == .unbound(item.operationID))
        #expect(s.session.notice == "Request failed.")
        #expect(s.session.bound == nil)
        #expect(s.session.selectedID == item.operationID)
    }

    @Test func reselectingSameIDIsIgnored() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        _ = s.select(item.operationID)
        #expect(s.send(.selectTapped(item.operationID)).isEmpty)
    }

    @Test func selectNilClearsSelection() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        _ = s.select(item.operationID)
        #expect(s.send(.selectTapped(nil)).isEmpty)
        #expect(s.session.selection == .none)
    }

    @Test func selectWhileDisconnectedSelectsNothing() {
        var s = Launch()
        #expect(s.send(.selectTapped(UUID())).isEmpty)
        #expect(s.session.selection == .none)
    }

    @Test func selectWhileBusyIgnored() {
        let a = reviewItem()
        let b = reviewItem()
        var s = Launch()
        s.connect(items: [a, b])
        let ticket = s.select(a.operationID)
        let bundle = launchBundle(a)
        s.send(.bindReplied(a.operationID, ticket: ticket, .success(bundle)))
        s.send(.allowTapped)
        #expect(s.session.isAuthorizing)
        #expect(s.send(.selectTapped(b.operationID)).isEmpty)
        #expect(s.send(.selectTapped(nil)).isEmpty)
        #expect(s.session.selection == .authorizing(bundle))
        s.send(.authenticated(challenge: bundle.challenge.challengeID, .authenticated))
        s.send(.completeReplied(challenge: bundle.challenge.challengeID, .success(.pendingReview)))
        s.send(.denyTapped)
        #expect(s.send(.selectTapped(b.operationID)).isEmpty)
        #expect(s.session.selectedID == a.operationID)
    }

    @Test func selectingAnotherWhileBindingRebinds() {
        let a = reviewItem()
        let b = reviewItem()
        var s = Launch()
        s.connect(items: [a, b])
        let ticketA = s.select(a.operationID)
        let ticketB = s.select(b.operationID)
        #expect(ticketB != ticketA)
        #expect(s.session.selection == .binding(b.operationID))
    }

    @Test func staleBindReplyDropped() {
        let a = reviewItem()
        let b = reviewItem()
        var s = Launch()
        s.connect(items: [a, b])
        let ticketA = s.select(a.operationID)
        let ticketB = s.select(b.operationID)
        s.send(.bindReplied(a.operationID, ticket: ticketA, .success(launchBundle(a))))
        #expect(s.session.selection == .binding(b.operationID))
        s.send(.bindReplied(a.operationID, ticket: ticketA,
            .failure(ReviewFailure(message: "Request failed."))))
        #expect(s.session.selection == .binding(b.operationID))
        #expect(s.session.notice == nil)
        let bundleB = launchBundle(b)
        s.send(.bindReplied(b.operationID, ticket: ticketB, .success(bundleB)))
        #expect(s.session.selection == .bound(bundleB))
    }

    @Test func staleSameIDBindReplyAfterReselectDropped() {
        let a = reviewItem()
        var s = Launch()
        s.connect(items: [a])
        let first = s.select(a.operationID)
        s.send(.selectTapped(nil))
        let second = s.select(a.operationID)
        s.send(.bindReplied(a.operationID, ticket: first,
            .failure(ReviewFailure(message: "Request failed."))))
        #expect(s.session.selection == .binding(a.operationID))
        let bundle = launchBundle(a)
        s.send(.bindReplied(a.operationID, ticket: second, .success(bundle)))
        #expect(s.session.selection == .bound(bundle))
    }

    @Test func mismatchedBindReplyIDFails() {
        let a = reviewItem()
        let other = reviewItem()
        var s = Launch()
        s.connect(items: [a, other])
        let ticket = s.select(a.operationID)
        s.send(.bindReplied(a.operationID, ticket: ticket, .success(launchBundle(other))))
        #expect(s.session.selection == .unbound(a.operationID))
        #expect(s.session.notice == "Request failed.")
        #expect(s.session.bound == nil)
    }

    // MARK: Authorize

    private func bound(_ s: inout Launch, _ item: UIReviewItemDTO) -> UIChallengeBundleDTO {
        s.connect(items: [item])
        let ticket = s.select(item.operationID)
        let bundle = launchBundle(item)
        s.send(.bindReplied(item.operationID, ticket: ticket, .success(bundle)))
        return bundle
    }

    @Test func allowWithoutBoundIsNoOp() {
        var s = Launch()
        #expect(s.send(.allowTapped).isEmpty)
        let item = reviewItem()
        s.connect(items: [item])
        _ = s.select(item.operationID)
        #expect(s.send(.allowTapped).isEmpty)
    }

    @Test func launchUnauthenticatedStillCompletes() {
        let item = reviewItem()
        var s = Launch()
        let bundle = bound(&s, item)
        #expect(s.send(.allowTapped) == [.authenticate(bundle)])
        let commands = s.send(.authenticated(
            challenge: bundle.challenge.challengeID, .cancelled))
        #expect(commands == [.complete(bundle, .cancelled)])
        #expect(s.session.notice == nil)
    }

    @Test func terminalClearsSelection() {
        let item = reviewItem()
        var s = Launch()
        let bundle = bound(&s, item)
        s.send(.allowTapped)
        s.send(.authenticated(challenge: bundle.challenge.challengeID, .authenticated))
        let commands = s.send(.completeReplied(
            challenge: bundle.challenge.challengeID, .success(.authorized)))
        #expect(s.session.selection == .none)
        #expect(s.session.lastStatus == .authorized)
        #expect(commands.count == 1)
    }

    @Test func nonTerminalKeepsBound() {
        let item = reviewItem()
        var s = Launch()
        let bundle = bound(&s, item)
        s.send(.allowTapped)
        s.send(.authenticated(challenge: bundle.challenge.challengeID, .authenticated))
        s.send(.completeReplied(
            challenge: bundle.challenge.challengeID, .success(.awaitingAuthentication)))
        #expect(s.session.selection == .bound(bundle))
    }

    @Test func completeFailureKeepsBoundWithNotice() {
        let item = reviewItem()
        var s = Launch()
        let bundle = bound(&s, item)
        s.send(.allowTapped)
        s.send(.authenticated(challenge: bundle.challenge.challengeID, .authenticated))
        let commands = s.send(.completeReplied(
            challenge: bundle.challenge.challengeID,
            .failure(ReviewFailure(message: "Lost connection to rvd."))))
        #expect(commands.isEmpty)
        #expect(s.session.selection == .bound(bundle))
        #expect(s.session.notice == "Lost connection to rvd.")
    }

    @Test func repliesForOtherChallengeDropped() {
        let item = reviewItem()
        var s = Launch()
        let bundle = bound(&s, item)
        s.send(.allowTapped)
        #expect(s.send(.authenticated(challenge: UUID(), .authenticated)).isEmpty)
        #expect(s.send(.completeReplied(challenge: UUID(), .success(.authorized))).isEmpty)
        #expect(s.session.selection == .authorizing(bundle))
        #expect(s.session.lastStatus == nil)
    }

    @Test func listWhileAuthorizingKeepsSelection() {
        let item = reviewItem()
        var s = Launch()
        let bundle = bound(&s, item)
        s.send(.allowTapped)
        let commands = s.send(.refreshRequested)
        guard case .list(let gen)? = commands.first else {
            Issue.record("no list")
            return
        }
        s.send(.listReplied(gen: gen, .success([])))
        #expect(s.session.items.isEmpty)
        #expect(s.session.selection == .authorizing(bundle))
        // Completion still addresses the bundle the user authenticated.
        let next = s.send(.authenticated(challenge: bundle.challenge.challengeID, .authenticated))
        #expect(next == [.complete(bundle, .authenticated)])
    }

    // MARK: Lists

    @Test func listPrunesVanishedSelection() {
        let item = reviewItem()
        var s = Launch()
        _ = bound(&s, item)
        let gen = refreshGen(&s)
        s.send(.listReplied(gen: gen, .success([])))
        #expect(s.session.selection == .none)
        #expect(s.session.notice == nil)
    }

    @Test func listPrunesBindingSelection() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        let ticket = s.select(item.operationID)
        let gen = refreshGen(&s)
        s.send(.listReplied(gen: gen, .success([])))
        #expect(s.session.selection == .none)
        s.send(.bindReplied(item.operationID, ticket: ticket, .success(launchBundle(item))))
        #expect(s.session.selection == .none)
    }

    @Test func listFailureSetsNoticeAndKeepsSelection() {
        let item = reviewItem()
        var s = Launch()
        let bundle = bound(&s, item)
        let gen = refreshGen(&s)
        s.send(.listReplied(gen: gen, .failure(ReviewFailure(message: "Request failed."))))
        #expect(s.session.notice == "Request failed.")
        #expect(s.session.selection == .bound(bundle))
    }

    @Test func olderListGenerationDropped() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        let older = refreshGen(&s)
        let newer = refreshGen(&s)
        s.send(.listReplied(gen: newer, .success([item])))
        s.send(.listReplied(gen: older, .success([])))
        s.send(.listReplied(gen: older, .failure(ReviewFailure(message: "Request failed."))))
        #expect(s.session.items == [item])
        #expect(s.session.notice == nil)
    }

    @Test func refreshWhileDisconnectedDoesNothing() {
        var s = Launch()
        #expect(s.send(.refreshRequested).isEmpty)
    }

    private func refreshGen(_ s: inout Launch) -> Int {
        guard case .list(let gen)? = s.send(.refreshRequested).first else {
            Issue.record("no list")
            return -1
        }
        return gen
    }

    // MARK: Deny

    @Test func launchDenyCancelsWithoutBind() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        _ = s.select(item.operationID)
        #expect(s.send(.denyTapped) == [.cancel(item.operationID)])
        #expect(s.session.selection == .denying(item.operationID, nil))
        let commands = s.send(.denyReplied(item.operationID, .success(.cancelled)))
        #expect(s.session.selection == .none)
        #expect(s.session.lastStatus == .cancelled)
        #expect(commands.count == 1)
    }

    @Test func launchDenyBoundCancelsByID() {
        let item = reviewItem()
        var s = Launch()
        let bundle = bound(&s, item)
        #expect(s.send(.denyTapped) == [.cancel(item.operationID)])
        #expect(s.session.selection == .denying(item.operationID, bundle))
        #expect(s.send(.denyTapped).isEmpty)
        #expect(s.send(.allowTapped).isEmpty)
    }

    @Test func denyFailureReturnsToUnboundOrBound() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        _ = s.select(item.operationID)
        s.send(.denyTapped)
        s.send(.denyReplied(item.operationID, .failure(ReviewFailure(message: "Request failed."))))
        #expect(s.session.selection == .unbound(item.operationID))

        var t = Launch()
        let bundle = bound(&t, item)
        t.send(.denyTapped)
        t.send(.denyReplied(item.operationID, .failure(ReviewFailure(message: "Request failed."))))
        #expect(t.session.selection == .bound(bundle))
    }

    @Test func launchBindReplyDuringDenyStillBinds() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        let ticket = s.select(item.operationID)
        s.send(.denyTapped)
        let bundle = launchBundle(item)
        #expect(s.send(.bindReplied(item.operationID, ticket: ticket, .success(bundle))).isEmpty)
        #expect(s.session.selection == .denying(item.operationID, bundle))
        s.send(.denyReplied(item.operationID, .failure(ReviewFailure(message: "Request failed."))))
        #expect(s.session.selection == .bound(bundle))
    }

    @Test func denyReplyForOtherIDDropped() {
        let item = reviewItem()
        var s = Launch()
        s.connect(items: [item])
        _ = s.select(item.operationID)
        s.send(.denyTapped)
        #expect(s.send(.denyReplied(UUID(), .success(.cancelled))).isEmpty)
        #expect(s.session.selection == .denying(item.operationID, nil))
    }

    @Test func unboundDenyRebindsThenDenies() {
        let item = actionReviewItem()
        var s = Script<ActionReview>()
        s.connect(items: [item])
        let first = s.select(item.approvalID)
        s.send(.bindReplied(item.approvalID, ticket: first,
            .failure(ReviewFailure(message: "Request failed."))))
        #expect(s.session.selection == .unbound(item.approvalID))
        guard case .bind(_, let ticket)? = s.send(.denyTapped).first else {
            Issue.record("deny did not bind")
            return
        }
        #expect(s.session.selection == .bindingToDeny(item.approvalID))
        // select is blocked while binding to deny
        #expect(s.send(.selectTapped(nil)).isEmpty)
        let bundle = actionBundle(item)
        let commands = s.send(.bindReplied(item.approvalID, ticket: ticket, .success(bundle)))
        #expect(commands == [.deny(bundle)])
        #expect(s.session.selection == .denying(item.approvalID, bundle))
        s.send(.denyReplied(item.approvalID, .success(.denied)))
        #expect(s.session.selection == .none)
    }

    @Test func actionDenyBoundDeniesBundle() {
        let item = actionReviewItem()
        var s = Script<ActionReview>()
        s.connect(items: [item])
        let ticket = s.select(item.approvalID)
        let bundle = actionBundle(item)
        s.send(.bindReplied(item.approvalID, ticket: ticket, .success(bundle)))
        #expect(s.send(.denyTapped) == [.deny(bundle)])
    }

    @Test func denyBindForVanishedReviewSendsNoDeny() {
        let item = actionReviewItem()
        var s = Script<ActionReview>()
        s.connect(items: [item])
        _ = s.select(item.approvalID)
        guard case .bind(_, let ticket)? = s.send(.denyTapped).first,
            case .list(let gen)? = s.send(.refreshRequested).first
        else {
            Issue.record("setup")
            return
        }
        s.send(.listReplied(gen: gen, .success([])))
        #expect(s.session.selection == .none)
        #expect(s.send(.bindReplied(item.approvalID, ticket: ticket,
            .success(actionBundle(item)))).isEmpty)
    }

    @Test func actionMismatchedDenyBindFails() {
        let item = actionReviewItem()
        let other = actionReviewItem()
        var s = Script<ActionReview>()
        s.connect(items: [item, other])
        _ = s.select(item.approvalID)
        guard case .bind(_, let ticket)? = s.send(.denyTapped).first else {
            Issue.record("setup")
            return
        }
        #expect(s.send(.bindReplied(item.approvalID, ticket: ticket,
            .success(actionBundle(other)))).isEmpty)
        #expect(s.session.selection == .unbound(item.approvalID))
        #expect(s.session.notice == "Request failed.")
    }

    // MARK: Hook

    private typealias HookScript = Script<HookReview>

    private func hookBound(_ s: inout HookScript, _ item: UIHookReviewItemDTO)
        -> UIHookChallengeBundleDTO
    {
        s.connect(items: [item])
        let ticket = s.select(item.approvalID)
        let bundle = hookBundle(item)
        s.send(.bindReplied(item.approvalID, ticket: ticket, .success(bundle)))
        return bundle
    }

    @Test func hookUnauthenticatedReturnsToBound() {
        let item = hookReviewItem()
        for outcome in [UIAuthenticationOutcome.cancelled, .failed, .unavailable, .timedOut, .invalidated] {
            var s = HookScript()
            let bundle = hookBound(&s, item)
            s.send(.allowTapped)
            let commands = s.send(.authenticated(
                challenge: bundle.challenge.challengeID, outcome))
            #expect(commands.isEmpty)
            #expect(s.session.selection == .bound(bundle))
            #expect(s.session.notice == HookReview.notAuthenticatedNotice(outcome))
            #expect(s.session.notice != nil)
        }
    }

    @Test func hookAuthenticatedCompletes() {
        let item = hookReviewItem()
        var s = HookScript()
        let bundle = hookBound(&s, item)
        s.send(.allowTapped)
        let commands = s.send(.authenticated(
            challenge: bundle.challenge.challengeID, .authenticated))
        #expect(commands == [.complete(bundle, .authenticated)])
    }

    @Test func hookUnavailableBlocksBeforePrompt() {
        let item = hookReviewItem(allowOnceAvailable: false)
        var s = HookScript()
        let bundle = hookBound(&s, item)
        #expect(s.send(.allowTapped).isEmpty)
        #expect(s.session.notice == "Allow once is unavailable for this request.")
        #expect(s.session.selection == .bound(bundle))
    }

    @Test func hookArrivalsBaselineOnConnectAndOpenOnSelect() {
        let existing = hookReviewItem(approvalID: "old")
        let fresh = hookReviewItem(approvalID: "new")
        var s = HookScript()
        s.connect(items: [existing])
        #expect(s.session.arrivals.unseen.isEmpty)
        guard case .list(let gen)? = s.send(.refreshRequested).first else {
            Issue.record("no list")
            return
        }
        s.send(.listReplied(gen: gen, .success([existing, fresh])))
        #expect(s.session.arrivals.unseen == ["new"])
        _ = s.select("new")
        #expect(s.session.arrivals.unseen.isEmpty)
    }

    @Test func hookFailedFirstListLeavesBaselineEmpty() {
        let existing = hookReviewItem(approvalID: "old")
        var s = HookScript()
        s.send(.connectRequested)
        s.send(.connectReplied(nil))
        s.send(.listReplied(gen: 1, .failure(ReviewFailure(message: "Request failed."))))
        guard case .list(let gen)? = s.send(.refreshRequested).first else {
            Issue.record("no list")
            return
        }
        s.send(.listReplied(gen: gen, .success([existing])))
        #expect(s.session.arrivals.unseen == ["old"])
    }

    @Test func hookMaintainRedialsWhileNotConnected() {
        var s = HookScript()
        #expect(s.send(.maintainTick) == [.connect])
        s.send(.connectReplied(ReviewFailure(message: "Lost connection to rvd.")))
        #expect(s.send(.maintainTick) == [.connect])
        s.send(.connectReplied(nil))
        s.send(.listReplied(gen: 1, .success([])))
        #expect(s.send(.maintainTick) == [.list(gen: 2)])
    }

    @Test func hookReconnectRebaselinesExistingItems() {
        let a = hookReviewItem(approvalID: "a")
        var s = HookScript()
        s.connect(items: [a])
        s.send(.connectReplied(ReviewFailure(message: "x")))  // drop to failed
        s.send(.connectRequested)
        let commands = s.send(.connectReplied(nil))
        guard case .list(let gen)? = commands.first else {
            Issue.record("no list")
            return
        }
        s.send(.listReplied(gen: gen, .success([a, hookReviewItem(approvalID: "b")])))
        #expect(s.session.arrivals.unseen.isEmpty)
    }

    // MARK: Invariant over scripted sequences

    @Test func invariantHoldsAfterEveryEvent() {
        let a = reviewItem()
        let b = reviewItem()
        let bundleA = launchBundle(a)
        let bundleB = launchBundle(b)
        var s = Launch()
        s.connect(items: [a, b])
        // Interleaved selects, replies in both orders, refreshes, deny, allow.
        let ta = s.select(a.operationID)
        let tb = s.select(b.operationID)
        s.send(.bindReplied(b.operationID, ticket: tb, .success(bundleB)))
        s.send(.bindReplied(a.operationID, ticket: ta, .success(bundleA)))
        s.send(.bindReplied(a.operationID, ticket: tb, .success(bundleA)))
        s.send(.allowTapped)
        s.send(.authenticated(challenge: bundleA.challenge.challengeID, .authenticated))
        s.send(.authenticated(challenge: bundleB.challenge.challengeID, .authenticated))
        s.send(.completeReplied(challenge: bundleB.challenge.challengeID, .success(.authorized)))
        s.send(.completeReplied(challenge: bundleB.challenge.challengeID, .success(.pendingReview)))
        s.send(.refreshRequested)
        s.send(.listReplied(gen: 99, .success([a])))
        s.send(.selectTapped(a.operationID))
        s.send(.selectTapped(nil))
        let tb2 = s.select(b.operationID)
        s.send(.listReplied(gen: 100, .success([a])))
        s.send(.bindReplied(b.operationID, ticket: tb2, .success(bundleB)))
        s.send(.denyTapped)
        s.send(.denyReplied(b.operationID, .success(.cancelled)))
        s.send(.dismissNotice)
        #expect(s.session.selection == .none)
    }
}

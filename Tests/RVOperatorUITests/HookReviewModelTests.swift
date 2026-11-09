import Foundation
import Synchronization
import Testing
import RVIPC
import RVOperatorUI

/// Scripted `OperatorHookUIBridge`. No XPC, no service: drives the
/// hook-review model through its exact production seam.
final class FakeHookBridge: OperatorHookUIBridge, Sendable {
    struct State: Sendable {
        var items: [UIHookReviewItemDTO] = []
        var bindRefused = false
        var connectThrows = false
        var completeResult: HookReviewStatus = .allowedOnce
        var denyResult: HookReviewStatus = .denied
        var connectCalls = 0
        var bindCalls = 0
        var completions: [UIHookCompletion] = []
        var denies: [UIHookDeny] = []
        var cancels: [String] = []
        var lastChallenge: [String: UUID] = [:]
        var bindGates: [String: Gate] = [:]
        var denyGate: Gate?
    }

    private let state = Mutex(State())

    func setItems(_ items: [UIHookReviewItemDTO]) {
        state.withLock { $0.items = items }
    }

    func setBindRefused(_ refused: Bool) {
        state.withLock { $0.bindRefused = refused }
    }

    func setConnectThrows(_ shouldThrow: Bool) {
        state.withLock { $0.connectThrows = shouldThrow }
    }

    /// Parks `hookBind(approvalID:)` for `id` until the returned gate is released.
    func gateBind(_ id: String) -> Gate {
        let gate = Gate()
        state.withLock { $0.bindGates[id] = gate }
        return gate
    }

    /// Parks `hookDeny(_:)` until the returned gate is released.
    func gateDeny() -> Gate {
        let gate = Gate()
        state.withLock { $0.denyGate = gate }
        return gate
    }

    var snapshot: State {
        state.withLock { $0 }
    }

    func connect() async throws {
        state.withLock { $0.connectCalls += 1 }
        if state.withLock({ $0.connectThrows }) {
            throw FakeBridgeError.refused
        }
    }

    func hookList() async throws -> UIHookReviewListDTO {
        UIHookReviewListDTO(items: state.withLock { $0.items })
    }

    func hookBind(approvalID: String) async throws -> UIHookChallengeBundleDTO {
        state.withLock { $0.bindCalls += 1 }
        if let gate = state.withLock({ $0.bindGates[approvalID] }) {
            await gate.pass()
        }
        let current = state.withLock { $0 }
        guard !current.bindRefused,
            let item = current.items.first(where: { $0.approvalID == approvalID })
        else {
            throw FakeBridgeError.refused
        }
        let challengeID: UUID
        if let existing = current.lastChallenge[approvalID] {
            challengeID = existing
        } else {
            challengeID = UUID()
            state.withLock { $0.lastChallenge[approvalID] = challengeID }
        }
        return UIHookChallengeBundleDTO(
            challenge: UIHookChallengeDTO(
                challengeID: challengeID, approvalID: approvalID,
                actionFingerprint: item.actionFingerprint, uiConnectionID: UUID(),
                issuedWall: Date(), advisoryLifetimeSeconds: 300),
            item: item)
    }

    func hookComplete(_ completion: UIHookCompletion) async throws -> UIHookStatusDTO {
        state.withLock { $0.completions.append(completion) }
        let status = state.withLock { $0.completeResult }
        return UIHookStatusDTO(approvalID: completion.approvalID, status: status)
    }

    func hookDeny(_ deny: UIHookDeny) async throws -> UIHookStatusDTO {
        state.withLock { $0.denies.append(deny) }
        if let gate = state.withLock({ $0.denyGate }) {
            await gate.pass()
        }
        let status = state.withLock { $0.denyResult }
        return UIHookStatusDTO(approvalID: deny.approvalID, status: status)
    }

    func hookCancel(approvalID: String) async throws -> UIHookStatusDTO {
        state.withLock { $0.cancels.append(approvalID) }
        return UIHookStatusDTO(approvalID: approvalID, status: .awaitingHuman)
    }

    func hookStatus(approvalID: String) async throws -> UIHookStatusDTO {
        UIHookStatusDTO(approvalID: approvalID, status: .awaitingHuman)
    }
}

func hookReviewItem(
    approvalID: String = "hook-1",
    status: HookReviewStatus = .awaitingHuman,
    allowOnceAvailable: Bool? = nil
) -> UIHookReviewItemDTO {
    UIHookReviewItemDTO(
        approvalID: approvalID, host: "pi", session: "sess-pi",
        actionKind: "shell", exactCommand: "git reset --hard",
        workingDirectory: "/tmp/ws", policyReason: "hostAsk",
        actionFingerprint: "pi:sess-pi:/tmp/ws:git reset --hard",
        status: status, advisoryExpiresWall: nil,
        allowOnceAvailable: allowOnceAvailable)
}

@Suite("Operator hook review model")
@MainActor
struct OperatorHookReviewModelTests {
    private func makeModel(
        bridge: FakeHookBridge = FakeHookBridge(),
        counter: AuthCounter = AuthCounter(),
        outcome: UIAuthenticationOutcome = .authenticated
    ) -> OperatorHookReviewModel {
        OperatorHookReviewModel(
            bridge: bridge, authenticator: counter.authenticator(outcome: outcome))
    }

    @Test func connectLoadsItems() async {
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem(), hookReviewItem(approvalID: "hook-2")])
        let model = makeModel(bridge: bridge)
        await model.connect()
        #expect(model.connection == .connected)
        #expect(model.items.count == 2)
        #expect(bridge.snapshot.connectCalls == 1)
    }

    @Test func passiveRequestsNeverAuthenticate() async {
        // Anti-prompt-spam: listing, refreshing, and opening a review never
        // start device-owner authentication. Only the explicit Allow-once
        // tap does.
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem()])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.refresh()
        await model.select("hook-1")
        await model.refresh()
        #expect(counter.calls == 0)
        #expect(model.bound != nil)
    }

    @Test func allowOnceEchoesExactRetainedChallenge() async throws {
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem()])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select("hook-1")
        let retained = try #require(model.bound)
        await model.allowOnce()
        #expect(counter.calls == 1)
        let completions = bridge.snapshot.completions
        #expect(completions.count == 1)
        #expect(completions[0].challengeID == retained.challenge.challengeID)
        #expect(completions[0].approvalID == "hook-1")
        #expect(completions[0].outcome == .authenticated)
        #expect(model.lastStatus == .allowedOnce)
        #expect(model.selectedID == nil)
        #expect(model.bound == nil)
    }

    @Test func allowOnceUsesFixedPrompt() async {
        let bridge = FakeHookBridge()
        // Even a hostile-looking item cannot shape the LA prompt: the
        // reason is a fixed string, and it names hook approval (not the
        // launch or action prompt) so the human knows the authority type.
        bridge.setItems([hookReviewItem()])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select("hook-1")
        await model.allowOnce()
        let reasons = counter.seenReasons
        #expect(reasons.count == 1)
        #expect(reasons[0].contains("coding-agent command"))
        #expect(!reasons[0].contains("Launch"))
        #expect(!reasons[0].contains("agent action"))
    }

    @Test func unavailableAllowOnceSkipsAuthentication() async throws {
        // File/http waits carry no exact command, so the server marks
        // them unavailable: the model must not spend a device-owner
        // authentication on a completion the server must refuse, and
        // must send nothing. Deny still works (separate test).
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem(allowOnceAvailable: false)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select("hook-1")
        _ = try #require(model.bound)
        #expect(model.allowOnceAvailable == false)
        await model.allowOnce()
        #expect(counter.calls == 0)
        #expect(bridge.snapshot.completions.isEmpty)
        #expect(model.notice != nil)
        #expect(model.bound != nil)
    }

    @Test func legacyNilAvailabilityStillAllows() async throws {
        // Older servers omit the flag: nil keeps previous behavior.
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem(allowOnceAvailable: nil)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select("hook-1")
        #expect(model.allowOnceAvailable == true)
        await model.allowOnce()
        #expect(counter.calls == 1)
        #expect(bridge.snapshot.completions.count == 1)
    }

    @Test func denyNeedsNoAuthentication() async throws {
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem()])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select("hook-1")
        let retained = try #require(model.bound)
        await model.deny()
        #expect(counter.calls == 0)
        let denies = bridge.snapshot.denies
        #expect(denies.count == 1)
        #expect(denies[0].challengeID == retained.challenge.challengeID)
        #expect(denies[0].approvalID == "hook-1")
        #expect(model.lastStatus == .denied)
        #expect(model.selectedID == nil)
    }

    @Test func cancelledAuthenticationSkipsCompleteAndKeepsReview() async throws {
        // A cancelled LA ceremony sends nothing: the server destroys the
        // challenge for an unauthenticated completion, so the model keeps
        // the bound review for a retry instead of burning it.
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem()])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter, outcome: .cancelled)
        await model.connect()
        await model.select("hook-1")
        let retained = try #require(model.bound)
        await model.allowOnce()
        #expect(counter.calls == 1)
        #expect(bridge.snapshot.completions.isEmpty)
        #expect(model.bound?.challenge.challengeID == retained.challenge.challengeID)
        #expect(model.selectedID == "hook-1")
        #expect(model.lastStatus == nil)
        #expect(model.notice != nil)
    }

    @Test func everyNonAuthenticatedOutcomeSkipsComplete() async {
        for outcome: UIAuthenticationOutcome in [
            .cancelled, .unavailable, .timedOut, .invalidated, .failed,
        ] {
            let bridge = FakeHookBridge()
            bridge.setItems([hookReviewItem()])
            let model = makeModel(bridge: bridge, outcome: outcome)
            await model.connect()
            await model.select("hook-1")
            await model.allowOnce()
            #expect(bridge.snapshot.completions.isEmpty, "outcome \(outcome) must not complete")
            #expect(model.bound != nil, "outcome \(outcome) must keep the bound review")
            #expect(model.notice != nil, "outcome \(outcome) must surface a notice")
        }
    }

    @Test func bindFailureSurfacesNotice() async {
        let bridge = FakeHookBridge()
        bridge.setBindRefused(true)
        bridge.setItems([hookReviewItem()])
        let model = makeModel(bridge: bridge)
        await model.connect()
        await model.select("hook-1")
        #expect(model.bound == nil)
        #expect(model.notice != nil)
    }

    @Test func connectBaselinesExistingItemsAsSeen() async {
        // Rows already pending when the app opens are the baseline, not
        // arrivals: the arrival signal must stay quiet for them.
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem(), hookReviewItem(approvalID: "hook-2")])
        let model = makeModel(bridge: bridge)
        await model.connect()
        #expect(model.items.count == 2)
        #expect(model.unseenApprovalIDs.isEmpty)
    }

    @Test func refreshFlagsNewArrivalsAsUnseen() async {
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem()])
        let model = makeModel(bridge: bridge)
        await model.connect()
        #expect(model.unseenApprovalIDs.isEmpty)
        bridge.setItems([hookReviewItem(), hookReviewItem(approvalID: "hook-2")])
        await model.refresh()
        #expect(model.items.count == 2)
        #expect(model.unseenApprovalIDs == ["hook-2"])
    }

    @Test func selectingAnArrivalClearsItFromUnseen() async {
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem()])
        let model = makeModel(bridge: bridge)
        await model.connect()
        bridge.setItems([hookReviewItem(), hookReviewItem(approvalID: "hook-2")])
        await model.refresh()
        #expect(model.unseenApprovalIDs == ["hook-2"])
        await model.select("hook-2")
        #expect(model.unseenApprovalIDs.isEmpty)
    }

    @Test func expiredArrivalsLeaveUnseen() async {
        // A row that vanishes server-side (expired/resolved elsewhere) is
        // no longer awaiting the human: it must not linger as unseen.
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem()])
        let model = makeModel(bridge: bridge)
        await model.connect()
        bridge.setItems([hookReviewItem(), hookReviewItem(approvalID: "hook-2")])
        await model.refresh()
        #expect(model.unseenApprovalIDs == ["hook-2"])
        bridge.setItems([hookReviewItem()])
        await model.refresh()
        #expect(model.unseenApprovalIDs.isEmpty)
    }

    @Test func maintainRefreshesWhenConnected() async {
        // The view's poll tick: one maintain() is one refresh, and it never
        // spends device-owner authentication.
        let bridge = FakeHookBridge()
        bridge.setItems([hookReviewItem()])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        bridge.setItems([hookReviewItem(), hookReviewItem(approvalID: "hook-2")])
        await model.maintain()
        #expect(model.items.count == 2)
        #expect(model.unseenApprovalIDs == ["hook-2"])
        #expect(counter.calls == 0)
    }

    @Test func maintainRetriesConnectWhileDisconnected() async {
        // After an rvd outage the view heals itself: maintain() keeps
        // redialing until the bridge answers, then baselines the list.
        let bridge = FakeHookBridge()
        bridge.setConnectThrows(true)
        let model = makeModel(bridge: bridge)
        await model.maintain()
        await model.maintain()
        #expect(model.connection != .connected)
        #expect(bridge.snapshot.connectCalls == 2)
        bridge.setConnectThrows(false)
        bridge.setItems([hookReviewItem()])
        await model.maintain()
        #expect(model.connection == .connected)
        #expect(model.items.count == 1)
        #expect(model.unseenApprovalIDs.isEmpty)
    }

    @Test func staleBindReplyNeverOverwritesNewerSelection() async {
        let bridge = FakeHookBridge()
        let first = "hook-a"
        let second = "hook-b"
        bridge.setItems([hookReviewItem(approvalID: first), hookReviewItem(approvalID: second)])
        let gateA = bridge.gateBind(first)
        let gateB = bridge.gateBind(second)
        let model = makeModel(bridge: bridge)
        await model.connect()
        let selectA = Task { await model.select(first) }
        await gateA.waitEntered()
        let selectB = Task { await model.select(second) }
        await gateB.waitEntered()
        gateB.release()
        await selectB.value
        #expect(model.bound?.item.approvalID == second)
        gateA.release()
        await selectA.value
        #expect(model.selectedID == second)
        #expect(model.bound?.item.approvalID == second)
        await model.allowOnce()
        #expect(bridge.snapshot.completions.map(\.approvalID) == [second])
    }

    @Test func staleBindFailureNeverSurfacesOverNewerSelection() async {
        let bridge = FakeHookBridge()
        let first = "hook-a"
        let second = "hook-b"
        // `first` is not listed, so its bind fails once released.
        bridge.setItems([hookReviewItem(approvalID: second)])
        let gateA = bridge.gateBind(first)
        let model = makeModel(bridge: bridge)
        await model.connect()
        let selectA = Task { await model.select(first) }
        await gateA.waitEntered()
        await model.select(second)
        #expect(model.bound?.item.approvalID == second)
        gateA.release()
        await selectA.value
        #expect(model.notice == nil)
        #expect(model.bound?.item.approvalID == second)
    }

    @Test func denyInFlightBlocksAllowAndSelect() async {
        let bridge = FakeHookBridge()
        let first = "hook-a"
        let second = "hook-b"
        bridge.setItems([hookReviewItem(approvalID: first), hookReviewItem(approvalID: second)])
        let gate = bridge.gateDeny()
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select(first)
        let denial = Task { await model.deny() }
        await gate.waitEntered()
        await model.select(second)
        await model.select(nil)
        await model.allowOnce()
        await model.deny()
        #expect(model.selectedID == first)
        #expect(counter.calls == 0)
        #expect(bridge.snapshot.completions.isEmpty)
        #expect(bridge.snapshot.denies.count == 1)
        #expect(bridge.snapshot.bindCalls == 1)
        gate.release()
        await denial.value
        #expect(model.selectedID == nil)
        #expect(model.bound == nil)
        #expect(model.lastStatus == .denied)
    }
}

extension FakeHookBridge {
    func setCompleteResultForTesting(_ status: HookReviewStatus) {
        state.withLock { $0.completeResult = status }
    }
}

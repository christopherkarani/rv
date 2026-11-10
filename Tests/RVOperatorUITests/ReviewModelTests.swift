import Foundation
import Synchronization
import Testing
import RVIPC
import RVOperatorUI

enum FakeBridgeError: Error {
    case refused
}

/// Test-released suspension point: the fake parks a bridge call here until the
/// test releases it, so reply ordering is scripted, never slept.
final class Gate: Sendable {
    private struct Inner {
        var entered = false
        var released = false
        var passWaiter: CheckedContinuation<Void, Never>?
        var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let inner = Mutex(Inner())

    /// Called by the fake: signals arrival, then suspends until `release()`.
    func pass() async {
        let waiters = inner.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.entered = true
            let waiters = state.enteredWaiters
            state.enteredWaiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = inner.withLock { state -> Bool in
                if state.released { return true }
                state.passWaiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Suspends the test until the fake's call has reached the gate.
    func waitEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = inner.withLock { state -> Bool in
                if state.entered { return true }
                state.enteredWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiter = inner.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            let waiter = state.passWaiter
            state.passWaiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

/// Scripted `OperatorUIBridge`. No XPC, no service: drives the review model
/// through its exact production seam.
final class FakeBridge: OperatorUIBridge, Sendable {
    struct State: Sendable {
        var items: [UIReviewItemDTO] = []
        var bindRefused = false
        var completeResult: WorkspaceOperationStatus = .authorized
        var connectCalls = 0
        var bindCalls = 0
        var completions: [UIOperatorCompletion] = []
        var cancels: [UUID] = []
        var lastChallenge: [UUID: UUID] = [:]
        var bindGates: [UUID: Gate] = [:]
        var cancelGate: Gate?
    }

    private let state = Mutex(State())

    func setItems(_ items: [UIReviewItemDTO]) {
        state.withLock { $0.items = items }
    }

    func setBindRefused(_ refused: Bool) {
        state.withLock { $0.bindRefused = refused }
    }

    func setCompleteResult(_ status: WorkspaceOperationStatus) {
        state.withLock { $0.completeResult = status }
    }

    /// Parks `bind(operationID:)` for `id` until the returned gate is released.
    func gateBind(_ id: UUID) -> Gate {
        let gate = Gate()
        state.withLock { $0.bindGates[id] = gate }
        return gate
    }

    /// Parks `cancel(operationID:)` until the returned gate is released.
    func gateCancel() -> Gate {
        let gate = Gate()
        state.withLock { $0.cancelGate = gate }
        return gate
    }

    var snapshot: State {
        state.withLock { $0 }
    }

    func connect() async throws {
        state.withLock { $0.connectCalls += 1 }
    }

    func list() async throws -> UIReviewListDTO {
        UIReviewListDTO(items: state.withLock { $0.items })
    }

    func bind(operationID: UUID) async throws -> UIChallengeBundleDTO {
        state.withLock { $0.bindCalls += 1 }
        if let gate = state.withLock({ $0.bindGates[operationID] }) {
            await gate.pass()
        }
        let current = state.withLock { $0 }
        guard !current.bindRefused,
            let item = current.items.first(where: { $0.operationID == operationID })
        else {
            throw FakeBridgeError.refused
        }
        let challengeID: UUID
        if let existing = current.lastChallenge[operationID] {
            challengeID = existing
        } else {
            challengeID = UUID()
            state.withLock { $0.lastChallenge[operationID] = challengeID }
        }
        return UIChallengeBundleDTO(
            challenge: UIChallengeDTO(
                challengeID: challengeID, operationID: operationID,
                intentDigestHex: item.intentDigestHex, kind: item.kind,
                uiConnectionID: UUID(), issuedWall: Date(), advisoryLifetimeSeconds: 120),
            item: item)
    }

    func complete(_ completion: UIOperatorCompletion) async throws -> UIOperationStatusDTO {
        let result = state.withLock { state -> WorkspaceOperationStatus in
            state.completions.append(completion)
            return state.completeResult
        }
        return UIOperationStatusDTO(operationID: completion.operationID, status: result)
    }

    func cancel(operationID: UUID) async throws -> UIOperationStatusDTO {
        state.withLock { $0.cancels.append(operationID) }
        if let gate = state.withLock({ $0.cancelGate }) {
            await gate.pass()
        }
        return UIOperationStatusDTO(operationID: operationID, status: .cancelled)
    }

    func status(operationID: UUID) async throws -> UIOperationStatusDTO {
        UIOperationStatusDTO(operationID: operationID, status: .pendingReview)
    }
}

final class AuthCounter: Sendable {
    private let count = Mutex(0)
    private let reasons = Mutex<[String]>([])
    var calls: Int { count.withLock { $0 } }
    var seenReasons: [String] { reasons.withLock { $0 } }

    func authenticator(outcome: UIAuthenticationOutcome) -> OperatorAuthenticator {
        OperatorAuthenticator(evaluate: { [self] reason in
            self.count.withLock { $0 += 1 }
            self.reasons.withLock { $0.append(reason) }
            return outcome
        })
    }
}

func reviewItem(operationID: UUID = UUID(), status: WorkspaceOperationStatus = .pendingReview) -> UIReviewItemDTO {
    UIReviewItemDTO(
        operationID: operationID, kind: "launchCustom", definitionID: nil,
        definitionRevisionDigest: nil, executable: "/bin/echo",
        expectedContentDigest: String(repeating: "a", count: 64),
        workspaceSessionID: UUID(), workingDirectory: "/tmp", arguments: [],
        io: .discard, environmentPolicy: "sealed",
        intentDigestHex: String(repeating: "c", count: 64), status: status,
        advisoryExpiresWall: nil)
}

@Suite("Operator review model")
@MainActor
struct OperatorReviewModelTests {
    private func makeModel(
        bridge: FakeBridge = FakeBridge(),
        counter: AuthCounter = AuthCounter(),
        outcome: UIAuthenticationOutcome = .authenticated
    ) -> OperatorReviewModel {
        OperatorReviewModel(bridge: bridge, authenticator: counter.authenticator(outcome: outcome))
    }

    @Test func connectLoadsItems() async {
        let bridge = FakeBridge()
        bridge.setItems([reviewItem(), reviewItem()])
        let model = makeModel(bridge: bridge)
        await model.connect()
        #expect(model.connection == .connected)
        #expect(model.items.count == 2)
        #expect(bridge.snapshot.connectCalls == 1)
    }

    @Test func connectIsIdempotentWhileConnected() async {
        let bridge = FakeBridge()
        let model = makeModel(bridge: bridge)
        await model.connect()
        await model.connect()
        #expect(bridge.snapshot.connectCalls == 1)
    }

    @Test func passiveRequestsNeverAuthenticate() async {
        let bridge = FakeBridge()
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.refresh()
        await model.select(id)
        #expect(counter.calls == 0)
        #expect(model.bound != nil)
    }

    @Test func authorizeEchoesExactRetainedChallenge() async throws {
        let bridge = FakeBridge()
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select(id)
        let retained = try #require(model.bound)
        await model.authorize()
        #expect(counter.calls == 1)
        let completions = bridge.snapshot.completions
        #expect(completions.count == 1)
        #expect(completions[0].challengeID == retained.challenge.challengeID)
        #expect(completions[0].operationID == id)
        #expect(completions[0].outcome == .authenticated)
        #expect(model.lastStatus == .authorized)
        #expect(model.selectedID == nil)
        #expect(model.bound == nil)
    }

    @Test func cancelledOutcomeIsReportedNotUpgraded() async {
        let bridge = FakeBridge()
        bridge.setCompleteResult(.failed)
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter, outcome: .cancelled)
        await model.connect()
        await model.select(id)
        await model.authorize()
        #expect(bridge.snapshot.completions.count == 1)
        #expect(bridge.snapshot.completions[0].outcome == .cancelled)
        #expect(model.lastStatus == .failed)
        #expect(model.selectedID == nil)
    }

    @Test func unavailableOutcomeIsReported() async {
        let bridge = FakeBridge()
        bridge.setCompleteResult(.failed)
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter, outcome: .unavailable)
        await model.connect()
        await model.select(id)
        await model.authorize()
        #expect(bridge.snapshot.completions[0].outcome == .unavailable)
    }

    @Test func denyCancelsWithoutAuthenticating() async {
        let bridge = FakeBridge()
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select(id)
        await model.deny()
        #expect(counter.calls == 0)
        #expect(bridge.snapshot.cancels == [id])
        #expect(model.lastStatus == .cancelled)
        #expect(model.selectedID == nil)
    }

    @Test func authorizeAndDenyWithoutSelectionAreNoOps() async {
        let bridge = FakeBridge()
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.authorize()
        await model.deny()
        #expect(counter.calls == 0)
        #expect(bridge.snapshot.completions.isEmpty)
        #expect(bridge.snapshot.cancels.isEmpty)
    }

    @Test func bindFailureSurfacesNotice() async {
        let bridge = FakeBridge()
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        bridge.setBindRefused(true)
        let model = makeModel(bridge: bridge)
        await model.connect()
        await model.select(id)
        #expect(model.bound == nil)
        #expect(model.notice != nil)
    }

    @Test func nonTerminalCompletionKeepsSelection() async {
        let bridge = FakeBridge()
        bridge.setCompleteResult(.awaitingAuthentication)
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        let model = makeModel(bridge: bridge)
        await model.connect()
        await model.select(id)
        await model.authorize()
        #expect(model.selectedID == id)
        #expect(model.bound != nil)
    }

    @Test func refreshDropsVanishedSelection() async {
        let bridge = FakeBridge()
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        let model = makeModel(bridge: bridge)
        await model.connect()
        await model.select(id)
        #expect(model.bound != nil)
        bridge.setItems([])
        await model.refresh()
        #expect(model.selectedID == nil)
        #expect(model.bound == nil)
    }

    @Test func reselectSameOperationDoesNotRebind() async throws {
        let bridge = FakeBridge()
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        let model = makeModel(bridge: bridge)
        await model.connect()
        await model.select(id)
        let first = try #require(model.bound).challenge.challengeID
        await model.select(id)
        #expect(try #require(model.bound).challenge.challengeID == first)
        #expect(bridge.snapshot.bindCalls == 1)
    }

    @Test func selectDifferentOperationBindsAgain() async throws {
        let bridge = FakeBridge()
        let first = UUID()
        let second = UUID()
        bridge.setItems([reviewItem(operationID: first), reviewItem(operationID: second)])
        let model = makeModel(bridge: bridge)
        await model.connect()
        await model.select(first)
        await model.select(second)
        #expect(bridge.snapshot.bindCalls == 2)
        #expect(model.selectedID == second)
    }

    @Test func staleBindReplyNeverOverwritesNewerSelection() async throws {
        let bridge = FakeBridge()
        let first = UUID()
        let second = UUID()
        bridge.setItems([reviewItem(operationID: first), reviewItem(operationID: second)])
        let gateA = bridge.gateBind(first)
        let gateB = bridge.gateBind(second)
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        let selectA = Task { await model.select(first) }
        await gateA.waitEntered()
        let selectB = Task { await model.select(second) }
        await gateB.waitEntered()
        gateB.release()
        await selectB.value
        #expect(model.bound?.item.operationID == second)
        gateA.release()
        await selectA.value
        #expect(model.selectedID == second)
        #expect(model.bound?.item.operationID == second)
        await model.authorize()
        #expect(bridge.snapshot.completions.map(\.operationID) == [second])
    }

    @Test func staleBindFailureNeverSurfacesOverNewerSelection() async {
        let bridge = FakeBridge()
        let first = UUID()
        let second = UUID()
        // `first` is not listed, so its bind fails once released.
        bridge.setItems([reviewItem(operationID: second)])
        let gateA = bridge.gateBind(first)
        let model = makeModel(bridge: bridge)
        await model.connect()
        let selectA = Task { await model.select(first) }
        await gateA.waitEntered()
        await model.select(second)
        #expect(model.bound?.item.operationID == second)
        gateA.release()
        await selectA.value
        #expect(model.notice == nil)
        #expect(model.bound?.item.operationID == second)
    }

    @Test func denyInFlightBlocksAllowAndSelect() async {
        let bridge = FakeBridge()
        let first = UUID()
        let second = UUID()
        bridge.setItems([reviewItem(operationID: first), reviewItem(operationID: second)])
        let gate = bridge.gateCancel()
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select(first)
        let denial = Task { await model.deny() }
        await gate.waitEntered()
        await model.select(second)
        await model.select(nil)
        await model.authorize()
        await model.deny()
        #expect(model.selectedID == first)
        #expect(counter.calls == 0)
        #expect(bridge.snapshot.completions.isEmpty)
        #expect(bridge.snapshot.cancels == [first])
        #expect(bridge.snapshot.bindCalls == 1)
        gate.release()
        await denial.value
        #expect(model.selectedID == nil)
        #expect(model.bound == nil)
        #expect(model.lastStatus == .cancelled)
    }

    @Test func launchDenyTargetsDisplayedReview() async {
        let bridge = FakeBridge()
        let first = UUID()
        let second = UUID()
        bridge.setItems([reviewItem(operationID: first), reviewItem(operationID: second)])
        let gateA = bridge.gateBind(first)
        let gateB = bridge.gateBind(second)
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        let selectA = Task { await model.select(first) }
        await gateA.waitEntered()
        let selectB = Task { await model.select(second) }
        await gateB.waitEntered()
        // A's reply lands while B is displayed: it must not become `bound`.
        gateA.release()
        await selectA.value
        #expect(model.bound == nil || model.bound?.item.operationID == model.selectedID)
        await model.authorize()
        #expect(bridge.snapshot.completions.isEmpty)
        await model.deny()
        #expect(bridge.snapshot.cancels == [second])
        gateB.release()
        await selectB.value
        #expect(model.selectedID == nil)
        #expect(model.bound == nil)
    }
}

@Suite("Operator authenticator seam")
struct OperatorAuthenticatorTests {
    @Test func seamOutcomeIsHonored() async {
        let authenticator = OperatorAuthenticator(evaluate: { _ in .authenticated })
        #expect(await authenticator.authenticate(reason: "test") == .authenticated)
    }

    @Test func seamReceivesReason() async {
        let seen = Mutex<String?>(nil)
        let authenticator = OperatorAuthenticator(evaluate: { reason in
            seen.withLock { $0 = reason }
            return .cancelled
        })
        #expect(await authenticator.authenticate(reason: "authorize X") == .cancelled)
        #expect(seen.withLock { $0 } == "authorize X")
    }

    @Test func eachOutcomePassesThrough() async {
        for outcome: UIAuthenticationOutcome in [
            .authenticated, .cancelled, .unavailable, .timedOut, .invalidated, .failed,
        ] {
            let authenticator = OperatorAuthenticator(evaluate: { _ in outcome })
            #expect(await authenticator.authenticate(reason: "t") == outcome)
        }
    }
}

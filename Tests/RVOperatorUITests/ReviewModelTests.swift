import Foundation
import Synchronization
import Testing
import RVIPC
import RVOperatorUI

enum FakeBridgeError: Error {
    case refused
}

/// Scripted `OperatorUIBridge`. No XPC, no service: drives the review model
/// through its exact production seam.
final class FakeBridge: OperatorUIBridge, Sendable {
    struct State: Sendable {
        var items: [UIReviewItemDTO] = []
        var bindRefused = false
        var completeResult = "authorized"
        var connectCalls = 0
        var completions: [UIOperatorCompletion] = []
        var cancels: [UUID] = []
        var lastChallenge: [UUID: UUID] = [:]
    }

    private let state = Mutex(State())

    func setItems(_ items: [UIReviewItemDTO]) {
        state.withLock { $0.items = items }
    }

    func setBindRefused(_ refused: Bool) {
        state.withLock { $0.bindRefused = refused }
    }

    func setCompleteResult(_ status: String) {
        state.withLock { $0.completeResult = status }
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
        let result = state.withLock { state -> String in
            state.completions.append(completion)
            return state.completeResult
        }
        return UIOperationStatusDTO(operationID: completion.operationID, status: result)
    }

    func cancel(operationID: UUID) async throws -> UIOperationStatusDTO {
        state.withLock { $0.cancels.append(operationID) }
        return UIOperationStatusDTO(operationID: operationID, status: "cancelled")
    }

    func status(operationID: UUID) async throws -> UIOperationStatusDTO {
        UIOperationStatusDTO(operationID: operationID, status: "pendingReview")
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

func reviewItem(operationID: UUID = UUID(), status: String = "pendingReview") -> UIReviewItemDTO {
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
        #expect(model.lastStatus == "authorized")
        #expect(model.selectedID == nil)
        #expect(model.bound == nil)
    }

    @Test func cancelledOutcomeIsReportedNotUpgraded() async {
        let bridge = FakeBridge()
        bridge.setCompleteResult("failed")
        let id = UUID()
        bridge.setItems([reviewItem(operationID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter, outcome: .cancelled)
        await model.connect()
        await model.select(id)
        await model.authorize()
        #expect(bridge.snapshot.completions.count == 1)
        #expect(bridge.snapshot.completions[0].outcome == .cancelled)
        #expect(model.lastStatus == "failed")
        #expect(model.selectedID == nil)
    }

    @Test func unavailableOutcomeIsReported() async {
        let bridge = FakeBridge()
        bridge.setCompleteResult("failed")
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
        #expect(model.lastStatus == "cancelled")
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
        bridge.setCompleteResult("awaitingAuthentication")
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

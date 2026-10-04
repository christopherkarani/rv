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
        var completeResult = "allowedOnce"
        var denyResult = "denied"
        var connectCalls = 0
        var bindCalls = 0
        var completions: [UIHookCompletion] = []
        var denies: [UIHookDeny] = []
        var cancels: [String] = []
        var lastChallenge: [String: UUID] = [:]
    }

    private let state = Mutex(State())

    func setItems(_ items: [UIHookReviewItemDTO]) {
        state.withLock { $0.items = items }
    }

    func setBindRefused(_ refused: Bool) {
        state.withLock { $0.bindRefused = refused }
    }

    var snapshot: State {
        state.withLock { $0 }
    }

    func connect() async throws {
        state.withLock { $0.connectCalls += 1 }
    }

    func hookList() async throws -> UIHookReviewListDTO {
        UIHookReviewListDTO(items: state.withLock { $0.items })
    }

    func hookBind(approvalID: String) async throws -> UIHookChallengeBundleDTO {
        state.withLock { $0.bindCalls += 1 }
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
        let status = state.withLock { $0.denyResult }
        return UIHookStatusDTO(approvalID: deny.approvalID, status: status)
    }

    func hookCancel(approvalID: String) async throws -> UIHookStatusDTO {
        state.withLock { $0.cancels.append(approvalID) }
        return UIHookStatusDTO(approvalID: approvalID, status: "awaitingHuman")
    }

    func hookStatus(approvalID: String) async throws -> UIHookStatusDTO {
        UIHookStatusDTO(approvalID: approvalID, status: "awaitingHuman")
    }
}

func hookReviewItem(approvalID: String = "hook-1", status: String = "awaitingHuman") -> UIHookReviewItemDTO {
    UIHookReviewItemDTO(
        approvalID: approvalID, host: "pi", session: "sess-pi",
        actionKind: "shell", exactCommand: "git reset --hard",
        workingDirectory: "/tmp/ws", policyReason: "hostAsk",
        actionFingerprint: "pi:sess-pi:/tmp/ws:git reset --hard",
        status: status, advisoryExpiresWall: nil)
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
        #expect(model.lastStatus == "allowedOnce")
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
        #expect(model.lastStatus == "denied")
        #expect(model.selectedID == nil)
    }

    @Test func cancelledAuthenticationStillCompletes() async {
        // A cancelled LA ceremony completes with the honest outcome (the
        // service fails the ceremony); the model reports it.
        let bridge = FakeHookBridge()
        bridge.setCompleteResultForTesting("failed")
        bridge.setItems([hookReviewItem()])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter, outcome: .cancelled)
        await model.connect()
        await model.select("hook-1")
        await model.allowOnce()
        #expect(counter.calls == 1)
        #expect(bridge.snapshot.completions.count == 1)
        #expect(bridge.snapshot.completions[0].outcome == .cancelled)
        #expect(model.lastStatus == "failed")
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
}

extension FakeHookBridge {
    func setCompleteResultForTesting(_ status: String) {
        state.withLock { $0.completeResult = status }
    }
}

import Foundation
import Synchronization
import Testing
import RVIPC
import RVOperatorUI

/// Scripted `OperatorActionUIBridge`. No XPC, no service: drives the
/// action-review model through its exact production seam.
final class FakeActionBridge: OperatorActionUIBridge, Sendable {
    struct State: Sendable {
        var items: [UIActionReviewItemDTO] = []
        var bindRefused = false
        var completeResult = "authorized"
        var denyResult = "denied"
        var connectCalls = 0
        var bindCalls = 0
        var completions: [UIActionCompletion] = []
        var denies: [UIActionDeny] = []
        var cancels: [UUID] = []
        var lastChallenge: [UUID: UUID] = [:]
    }

    private let state = Mutex(State())

    func setItems(_ items: [UIActionReviewItemDTO]) {
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

    func actionList() async throws -> UIActionReviewListDTO {
        UIActionReviewListDTO(items: state.withLock { $0.items })
    }

    func actionBind(approvalID: UUID) async throws -> UIActionChallengeBundleDTO {
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
        return UIActionChallengeBundleDTO(
            challenge: UIActionChallengeDTO(
                challengeID: challengeID, approvalID: approvalID,
                actionDigestHex: item.actionDigestHex, uiConnectionID: UUID(),
                issuedWall: Date(), advisoryLifetimeSeconds: 300),
            item: item)
    }

    func actionComplete(_ completion: UIActionCompletion) async throws -> UIActionStatusDTO {
        state.withLock { $0.completions.append(completion) }
        let status = state.withLock { $0.completeResult }
        return UIActionStatusDTO(approvalID: completion.approvalID, status: status)
    }

    func actionDeny(_ deny: UIActionDeny) async throws -> UIActionStatusDTO {
        state.withLock { $0.denies.append(deny) }
        let status = state.withLock { $0.denyResult }
        return UIActionStatusDTO(approvalID: deny.approvalID, status: status)
    }

    func actionCancel(approvalID: UUID) async throws -> UIActionStatusDTO {
        state.withLock { $0.cancels.append(approvalID) }
        return UIActionStatusDTO(approvalID: approvalID, status: "cancelled")
    }

    func actionStatus(approvalID: UUID) async throws -> UIActionStatusDTO {
        UIActionStatusDTO(approvalID: approvalID, status: "pending")
    }
}

func actionReviewItem(approvalID: UUID = UUID(), status: String = "pending") -> UIActionReviewItemDTO {
    UIActionReviewItemDTO(
        approvalID: approvalID, instanceID: UUID(), definitionID: "test-agent",
        definitionRevisionDigest: String(repeating: "c", count: 64),
        runtimeSessionID: UUID(), workspaceSessionID: UUID(), hostID: UUID(),
        actionKind: "shell", exactTarget: "/work", exactArguments: "echo hello",
        policyReason: "reviewAsk",
        scopeSummary: "Allow once: this exact action, single use.",
        actionDigestHex: String(repeating: "d", count: 64), status: status,
        advisoryExpiresWall: nil)
}

@Suite("Operator action review model")
@MainActor
struct OperatorActionReviewModelTests {
    private func makeModel(
        bridge: FakeActionBridge = FakeActionBridge(),
        counter: AuthCounter = AuthCounter(),
        outcome: UIAuthenticationOutcome = .authenticated
    ) -> OperatorActionReviewModel {
        OperatorActionReviewModel(
            bridge: bridge, authenticator: counter.authenticator(outcome: outcome))
    }

    @Test func connectLoadsItems() async {
        let bridge = FakeActionBridge()
        bridge.setItems([actionReviewItem(), actionReviewItem()])
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
        let bridge = FakeActionBridge()
        let id = UUID()
        bridge.setItems([actionReviewItem(approvalID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.refresh()
        await model.select(id)
        await model.refresh()
        #expect(counter.calls == 0)
        #expect(model.bound != nil)
    }

    @Test func allowOnceEchoesExactRetainedChallenge() async throws {
        let bridge = FakeActionBridge()
        let id = UUID()
        bridge.setItems([actionReviewItem(approvalID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select(id)
        let retained = try #require(model.bound)
        await model.allowOnce()
        #expect(counter.calls == 1)
        let completions = bridge.snapshot.completions
        #expect(completions.count == 1)
        #expect(completions[0].challengeID == retained.challenge.challengeID)
        #expect(completions[0].approvalID == id)
        #expect(completions[0].outcome == .authenticated)
        #expect(model.lastStatus == "authorized")
        #expect(model.selectedID == nil)
        #expect(model.bound == nil)
    }

    @Test func allowOnceUsesFixedPrompt() async {
        let bridge = FakeActionBridge()
        let id = UUID()
        // Even a hostile-looking item cannot shape the LA prompt: the
        // reason is a fixed string, and it names action approval (not the
        // launch prompt) so the human knows the authority type.
        bridge.setItems([actionReviewItem(approvalID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select(id)
        await model.allowOnce()
        let reasons = counter.seenReasons
        #expect(reasons.count == 1)
        #expect(reasons[0].contains("agent action"))
        #expect(!reasons[0].contains("Launch"))
    }

    @Test func denyNeedsNoAuthentication() async throws {
        let bridge = FakeActionBridge()
        let id = UUID()
        bridge.setItems([actionReviewItem(approvalID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter)
        await model.connect()
        await model.select(id)
        let retained = try #require(model.bound)
        await model.deny()
        #expect(counter.calls == 0)
        let denies = bridge.snapshot.denies
        #expect(denies.count == 1)
        #expect(denies[0].challengeID == retained.challenge.challengeID)
        #expect(denies[0].approvalID == id)
        #expect(model.lastStatus == "denied")
        #expect(model.selectedID == nil)
    }

    @Test func cancelledAuthenticationStillCompletes() async {
        // A cancelled LA ceremony completes with the honest outcome (the
        // service terminally fails the approval); the model reports it.
        let bridge = FakeActionBridge()
        bridge.setCompleteResultForTesting("failed")
        let id = UUID()
        bridge.setItems([actionReviewItem(approvalID: id)])
        let counter = AuthCounter()
        let model = makeModel(bridge: bridge, counter: counter, outcome: .cancelled)
        await model.connect()
        await model.select(id)
        await model.allowOnce()
        #expect(counter.calls == 1)
        #expect(bridge.snapshot.completions.count == 1)
        #expect(bridge.snapshot.completions[0].outcome == .cancelled)
        #expect(model.lastStatus == "failed")
    }

    @Test func bindFailureSurfacesNotice() async {
        let bridge = FakeActionBridge()
        bridge.setBindRefused(true)
        let id = UUID()
        bridge.setItems([actionReviewItem(approvalID: id)])
        let model = makeModel(bridge: bridge)
        await model.connect()
        await model.select(id)
        #expect(model.bound == nil)
        #expect(model.notice != nil)
    }
}

extension FakeActionBridge {
    func setCompleteResultForTesting(_ status: String) {
        state.withLock { $0.completeResult = status }
    }
}

@Suite("Review display escaping")
struct ReviewDisplayEscapeTests {
    @Test func plainTextPassesThrough() {
        #expect(ReviewDisplayEscape.escape("echo hello") == "echo hello")
        #expect(ReviewDisplayEscape.escape("/tmp/some file.txt") == "/tmp/some file.txt")
        #expect(ReviewDisplayEscape.escape("a > b.txt 2>&1") == "a > b.txt 2>&1")
    }

    @Test func newlinesTabsCarriageReturnsEscapeShort() {
        #expect(ReviewDisplayEscape.escape("a\nb") == "a\\nb")
        #expect(ReviewDisplayEscape.escape("a\tb") == "a\\tb")
        #expect(ReviewDisplayEscape.escape("a\rb") == "a\\rb")
    }

    @Test func bidiControlsBecomeVisible() {
        // U+202E RIGHT-TO-LEFT OVERRIDE: the classic filename spoof.
        #expect(ReviewDisplayEscape.escape("evil\u{202E}txt.exe") == "evil\\u{202E}txt.exe")
        // Isolates, embeddings, marks: all visible.
        #expect(ReviewDisplayEscape.escape("\u{2066}x\u{2069}") == "\\u{2066}x\\u{2069}")
        #expect(ReviewDisplayEscape.escape("\u{200E}x") == "\\u{200E}x")
        #expect(ReviewDisplayEscape.escape("\u{061C}x") == "\\u{61C}x")
    }

    @Test func otherControlsBecomeVisible() {
        #expect(ReviewDisplayEscape.escape("a\u{07}b") == "a\\u{7}b")
        #expect(ReviewDisplayEscape.escape("a\u{7F}b") == "a\\u{7F}b")
        #expect(ReviewDisplayEscape.escape("a\u{2028}b") == "a\\u{2028}b")
    }

    @Test func nothingIsTruncated() {
        let long = String(repeating: "x", count: 10_000)
        #expect(ReviewDisplayEscape.escape(long) == long)
    }

    @Test func idempotent() {
        let hostile = "a\nb\u{202E}c\u{07}d"
        let once = ReviewDisplayEscape.escape(hostile)
        #expect(ReviewDisplayEscape.escape(once) == once)
    }
}

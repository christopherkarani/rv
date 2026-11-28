import Foundation
import Synchronization
import Testing
import RVDomain
import RVIPC
@testable import RVGlance

/// K2 on the menu bar's side: what the sheet shows, and the reducer that
/// never sends an answer without a fresh Touch ID for it.
struct UnlockReviewTests {
    static let code = "a7c835"
    static let hash = String(repeating: "ab", count: 32)
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func item(
        command: String = "git push --force-with-lease origin feat/menubar", says: String? = "The remote moved.",
        approvable: Bool = true, hash: String = hash, code: String = code
    ) -> UIUnlockItemDTO {
        UIUnlockItemDTO(
            codeHash: hash, code: code, checkWords: ["not", "these", "words"], host: .claude, command: command,
            workingDirectory: "/Users/chris/rv", rule: "core.git:push-force", agentSays: says,
            promptText: approvable ? "allow once \"\(command)\" in /Users/chris/rv" : nil,
            status: .waiting, advisoryExpiresWall: now.addingTimeInterval(12 * 60 + 5))
    }

    static func bundle(_ item: UIUnlockItemDTO = item(), challenge: UUID = UUID()) -> UIUnlockChallengeBundleDTO {
        UIUnlockChallengeBundleDTO(
            challenge: UIUnlockChallengeDTO(
                challengeID: challenge, codeHash: item.codeHash, uiConnectionID: UUID(), issuedWall: now,
                advisoryLifetimeSeconds: 300),
            item: item)
    }

    /// A review on the sheet, bound to `bundle`.
    static func reviewing(_ bundle: UIUnlockChallengeBundleDTO) -> UnlockReview {
        var review = UnlockReview()
        _ = review.reduce(.openTapped(codeHash: bundle.item.codeHash, then: nil))
        _ = review.reduce(.bindReplied(codeHash: bundle.item.codeHash, .success(bundle)))
        return review
    }

    // MARK: The sheet

    @Test func theSheetShowsTheWholeCommandTheAgentsWordsAsTheAgentsAndTheTerminalsWords() throws {
        let long = "git push --force origin " + String(repeating: "feature-", count: 60)
        let sheet = UnlockSheet(Self.item(command: long), now: Self.now)
        #expect(sheet.command == long)
        #expect(sheet.agentSaysLabel == "claude says")
        #expect(sheet.agentSays == "The remote moved.")
        // Worked out from the code, as `rv wait` does, never from the reply.
        let words = CheckWords.line(for: try #require(AllowOnceUnlockCode(validating: Self.code)))
        #expect(sheet.checkWords == "Check the words in your terminal: \(words)")
        #expect(sheet.checkWords.contains("not") == false)
        #expect(sheet.codeLine == "code a7c835 · rule core.git:push-force")
        #expect(sheet.who == "Claude Code · /Users/chris/rv")
        #expect(sheet.subtitle == "claude is waiting · expires in 12m")
        #expect(sheet.canApprove)
    }

    @Test func aCommandThePromptCannotShowOrAnUnreadableCodeCannotBeApproved() {
        #expect(UnlockSheet(Self.item(approvable: false), now: Self.now).canApprove == false)
        #expect(UnlockSheet(Self.item(code: "zz"), now: Self.now).canApprove == false)
        var review = Self.reviewing(Self.bundle(Self.item(approvable: false)))
        #expect(review.reduce(.allowTapped(.allowOnce)).isEmpty)
        #expect(review.notice != nil)
    }

    @Test func theTouchIDReasonNamesOnlyTheCodeAndItsWords() throws {
        let code = try #require(AllowOnceUnlockCode(validating: Self.code))
        #expect(UnlockSheet.touchIDReason(code: code, decision: .allowOnce)
            == "allow the stopped command once (code a7c835, \(CheckWords.line(for: code)))")
        #expect(UnlockSheet.touchIDReason(code: code, decision: .alwaysAllow).hasPrefix("always allow"))
    }

    // MARK: The reducer

    @Test func allowAsksTouchIDThenEchoesTheBoundChallengeOnce() {
        let challenge = UUID()
        let bundle = Self.bundle(challenge: challenge)
        var review = Self.reviewing(bundle)
        let ask = review.reduce(.allowTapped(.allowOnce))
        guard case .authenticate(challenge, .allowOnce, _) = ask.first, ask.count == 1 else {
            Issue.record("allow must ask Touch ID first, got \(ask)")
            return
        }
        #expect(review.isBusy)
        // A second tap while the prompt is up does nothing.
        #expect(review.reduce(.allowTapped(.allowOnce)).isEmpty)
        let sent = review.reduce(.authenticated(challenge: challenge, .allowOnce, .authenticated))
        #expect(sent == [.complete(UIUnlockCompletion(
            challengeID: challenge, codeHash: Self.hash, decision: .allowOnce, outcome: .authenticated))])
        #expect(review.reduce(.completeReplied(challenge: challenge, .success(.allowedOnce))) == [.list])
        #expect(review.phase == .answered(codeHash: Self.hash, .allowedOnce))
        // A late duplicate reply changes nothing.
        #expect(review.reduce(.completeReplied(challenge: challenge, .success(.allowedOnce))).isEmpty)
    }

    @Test func everyAttemptAsksAgainAndAFailedPromptSendsNothing() {
        let challenge = UUID()
        var review = Self.reviewing(Self.bundle(challenge: challenge))
        for outcome in [UIAuthenticationOutcome.cancelled, .failed, .unavailable, .timedOut, .invalidated] {
            #expect(review.reduce(.allowTapped(.alwaysAllow)).count == 1)
            #expect(review.reduce(.authenticated(challenge: challenge, .alwaysAllow, outcome)).isEmpty)
            #expect(review.onSheet?.challenge.challengeID == challenge)
            #expect(review.notice?.contains("Nothing was allowed") == true
                || review.notice?.contains("aren't available") == true)
        }
    }

    @Test func aStrayAuthenticationOrReplyIsIgnored() {
        let challenge = UUID()
        var review = Self.reviewing(Self.bundle(challenge: challenge))
        _ = review.reduce(.allowTapped(.allowOnce))
        // Another challenge, or the other answer than the one asked.
        #expect(review.reduce(.authenticated(challenge: UUID(), .allowOnce, .authenticated)).isEmpty)
        #expect(review.reduce(.authenticated(challenge: challenge, .alwaysAllow, .authenticated)).isEmpty)
        #expect(review.reduce(.completeReplied(challenge: challenge, .success(.allowedOnce))).isEmpty)
    }

    @Test func aRefusedAnswerNeedsAFreshReview() {
        let challenge = UUID()
        var review = Self.reviewing(Self.bundle(challenge: challenge))
        _ = review.reduce(.allowTapped(.allowOnce))
        _ = review.reduce(.authenticated(challenge: challenge, .allowOnce, .authenticated))
        #expect(review.reduce(.completeReplied(challenge: challenge, .failure(.refused))) == [.list])
        #expect(review.phase == .idle)
        #expect(review.reduce(.allowTapped(.allowOnce)).isEmpty)
    }

    @Test func denySendsNoAnswerAndHidesTheAskUntilRvdDropsIt() {
        var review = Self.reviewing(Self.bundle())
        _ = review.reduce(.listReplied(.success([Self.item()])))
        #expect(review.reduce(.denyTapped) == [.release(codeHash: Self.hash)])
        #expect(review.phase == .idle)
        #expect(review.waiting.isEmpty)
        _ = review.reduce(.listReplied(.success([])))
        #expect(review.dismissed.isEmpty)
    }

    @Test func aBindForAnotherAskThanTheOneOpenedIsRefused() {
        var review = UnlockReview()
        _ = review.reduce(.openTapped(codeHash: Self.hash, then: .allowOnce))
        let other = Self.bundle(Self.item(hash: String(repeating: "cd", count: 32)))
        #expect(review.reduce(.bindReplied(codeHash: Self.hash, .success(other))) == [.list])
        #expect(review.onSheet == nil)
    }

    @Test func anAskAnsweredElsewhereLeavesTheSheet() {
        var review = Self.reviewing(Self.bundle())
        _ = review.reduce(.listReplied(.success([])))
        #expect(review.phase == .idle)
        #expect(review.notice != nil)
    }

    // MARK: The banner

    @Test func allowOnceOnABannerOpensTheSheetAndStartsTouchIDNeverAnAnswer() async {
        let route = UnlockNoticeAction.route(actionID: UnlockNoticeAction.allowOnce, codeHash: Self.hash)
        #expect(route == UnlockNoticeAction.Route(codeHash: Self.hash, then: .allowOnce))
        #expect(UnlockNoticeAction.route(actionID: UnlockNoticeAction.openBanner, codeHash: Self.hash)?.then == nil)
        #expect(UnlockNoticeAction.route(actionID: UnlockNoticeAction.dismissBanner, codeHash: Self.hash) == nil)
        #expect(UnlockNoticeAction.route(actionID: UnlockNoticeAction.allowOnce, codeHash: "a7c835") == nil)
        #expect(UnlockNoticeAction.route(actionID: UnlockNoticeAction.allowOnce, codeHash: nil) == nil)

        // Driven end to end through the runner: the prompt is asked, and
        // only its yes reaches rvd.
        for (outcome, completes) in [(UIAuthenticationOutcome.authenticated, true), (.cancelled, false)] {
            let bridge = FakeBridge(bundle: Self.bundle())
            var review = UnlockReview()
            await UnlockReviewRunner.send(
                .openTapped(codeHash: Self.hash, then: .allowOnce), to: &review, bridge: bridge,
                authenticator: FixedAuthenticator(outcome))
            #expect(bridge.completions.withLock { $0.count } == (completes ? 1 : 0))
            #expect(bridge.prompts.withLock { $0 } == 0)
        }
    }

    @Test func oneUnlockableStopGetsABannerThatCanOpenItAndNoCommandText() {
        var etiquette = GlanceEtiquette()
        var empty = GlanceSamples.state(.guarding)
        empty.pending = [:]
        var one = empty
        one.unlocks = [Self.hash: GlanceUnlockAsk(codeHash: Self.hash, host: .claude, checkWords: "orchid · rocket · crane")]
        let posted = etiquette.plan(from: empty, to: one, now: Self.now).compactMap { action -> GlanceNotice? in
            if case .post(let notice) = action { return notice }
            return nil
        }
        #expect(posted.count == 1)
        #expect(posted.first?.level == .timeSensitive)
        #expect(posted.first?.unlockCodeHash == Self.hash)
        #expect(posted.first?.body.contains("orchid · rocket · crane") == true)
        #expect(posted.first?.body.contains("git") == false)
        #expect(one.glyph(at: Self.now) == .needsYou)

        // A second ask from the same agent: one quiet banner, no single target.
        var two = one
        two.pending = [ApprovalID(rawValue: "ask-1"): .claude]
        let grouped = etiquette.plan(from: one, to: two, now: Self.now.addingTimeInterval(5))
        guard case .post(let notice) = grouped.first, grouped.count == 1 else {
            Issue.record("expected one grouped banner, got \(grouped)")
            return
        }
        #expect(notice.level == .passive)
        #expect(notice.unlockCodeHash == nil)
        #expect(notice.body == "2 from claude · answer in the menu bar")
    }
}

final class FakeBridge: UnlockBridge {
    let bundle: UIUnlockChallengeBundleDTO
    let completions = Mutex<[UIUnlockCompletion]>([])
    /// The bridge never prompts: only the authenticator does.
    let prompts = Mutex(0)

    init(bundle: UIUnlockChallengeBundleDTO) {
        self.bundle = bundle
    }

    func list() async throws -> UIUnlockListDTO { UIUnlockListDTO(items: [bundle.item]) }
    func bind(codeHash: String) async throws -> UIUnlockChallengeBundleDTO { bundle }
    func complete(_ completion: UIUnlockCompletion) async throws -> UIUnlockStatusDTO {
        completions.withLock { $0.append(completion) }
        return UIUnlockStatusDTO(codeHash: completion.codeHash, status: .allowedOnce)
    }
    func release(codeHash: String) async throws -> UIUnlockStatusDTO {
        UIUnlockStatusDTO(codeHash: codeHash, status: .waiting)
    }
}

struct FixedAuthenticator: UnlockAuthenticator {
    let outcome: UIAuthenticationOutcome

    init(_ outcome: UIAuthenticationOutcome) {
        self.outcome = outcome
    }

    func authenticate(reason: String) async -> UIAuthenticationOutcome { outcome }
}

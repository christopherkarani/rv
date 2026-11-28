import Foundation
import Synchronization
import Testing
import RVDomain
import RVIPC
@testable import RVGlance

/// K2 on the menu bar's side: what the sheet shows, and the reducer that
/// starts Touch ID only from an Allow tap on the sheet showing the whole
/// command, and never sends an answer without that prompt's outcome.
struct UnlockReviewTests {
    static let code = "a7c835"
    static let hash = String(repeating: "ab", count: 32)
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func item(
        command: String = "git push --force-with-lease origin feat/menubar", says: String? = "The remote moved.",
        approvable: Bool = true, hash: String = hash, code: String = code, status: UIUnlockStatus = .waiting
    ) -> UIUnlockItemDTO {
        UIUnlockItemDTO(
            codeHash: hash, code: code, checkWords: ["not", "these", "words"], host: .claude, command: command,
            effect: "Would overwrite the remote branch", workingDirectory: "/Users/chris/rv",
            rule: "core.git:push-force", agentSays: says,
            promptText: approvable
                ? "allow once \"\(command)\" in /Users/chris/rv (rule core.git:push-force, code \(code))" : nil,
            status: status, advisoryExpiresWall: now.addingTimeInterval(12 * 60 + 5))
    }

    static func row(hash: String = hash, code: String = code) -> UIUnlockSummaryDTO {
        UIUnlockSummaryDTO(codeHash: hash, code: code, host: .claude, advisoryExpiresWall: now.addingTimeInterval(600))
    }

    static func listed(_ rows: [UIUnlockSummaryDTO], omitted: Int = 0) -> UnlockReview.Event {
        .listReplied(.success(UIUnlockListDTO(items: rows, omitted: omitted)))
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
        _ = review.reduce(.openTapped(codeHash: bundle.item.codeHash))
        _ = review.reduce(.bindReplied(codeHash: bundle.item.codeHash, .success(bundle)))
        return review
    }

    // MARK: The sheet

    @Test func theSheetShowsTheWholeCommandTheAgentsWordsAsTheAgentsAndTheTerminalsWords() throws {
        let long = "git push --force origin " + String(repeating: "feature-", count: 60)
        let challenge = UUID()
        let sheet = UnlockSheet(Self.item(command: long), challengeID: challenge, now: Self.now)
        #expect(sheet.command == long)
        #expect(sheet.challengeID == challenge)
        // rvd's line, worded from its own raw copy of the command.
        #expect(sheet.effect == "Would overwrite the remote branch")
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

    @Test func aCommandThePromptCannotShowAnUnreadableCodeOrALockoutCannotBeApproved() {
        #expect(UnlockSheet(Self.item(approvable: false), now: Self.now).canApprove == false)
        #expect(UnlockSheet(Self.item(code: "zz"), now: Self.now).canApprove == false)
        let locked = UnlockSheet(Self.item(status: .lockedOut), now: Self.now)
        #expect(locked.canApprove == false)
        #expect(locked.unavailable == UnlockSheet.lockedOutLine)
        for item in [Self.item(approvable: false), Self.item(status: .lockedOut)] {
            let challenge = UUID()
            var review = Self.reviewing(Self.bundle(item, challenge: challenge))
            #expect(review.reduce(.allowTapped(challenge: challenge, .allowOnce)).isEmpty)
            #expect(review.notice != nil)
        }
    }

    /// Review blocker 1(b): the system prompt names the command in rvd's
    /// own words (the terminal's), with the check words, never the agent's.
    @Test func theTouchIDReasonIsRvdsPromptTextAndTheCheckWords() throws {
        let item = Self.item(command: "rm -rf ~/work", says: "run the tests")
        let words = CheckWords.line(for: try #require(AllowOnceUnlockCode(validating: Self.code)))
        let once = try #require(UnlockSheet.touchIDReason(item, decision: .allowOnce))
        #expect(once == "\(try #require(item.promptText)), check words \(words)")
        #expect(once.contains("rm -rf ~/work"))
        #expect(once.contains("run the tests") == false)
        let always = try #require(UnlockSheet.touchIDReason(item, decision: .alwaysAllow))
        #expect(always.hasPrefix("always allow from now on, and allow once \"rm -rf ~/work\""))
        #expect(UnlockSheet.touchIDReason(Self.item(approvable: false), decision: .allowOnce) == nil)

        // The reducer asks with exactly that reason.
        let challenge = UUID()
        var review = Self.reviewing(Self.bundle(item, challenge: challenge))
        #expect(review.reduce(.allowTapped(challenge: challenge, .allowOnce))
            == [.authenticate(challenge: challenge, .allowOnce, reason: once)])
    }

    // MARK: The reducer

    @Test func allowAsksTouchIDThenEchoesTheBoundChallengeOnce() {
        let challenge = UUID()
        let bundle = Self.bundle(challenge: challenge)
        var review = Self.reviewing(bundle)
        let ask = review.reduce(.allowTapped(challenge: challenge, .allowOnce))
        guard case .authenticate(challenge, .allowOnce, _) = ask.first, ask.count == 1 else {
            Issue.record("allow must ask Touch ID first, got \(ask)")
            return
        }
        #expect(review.isBusy)
        // A second tap while the prompt is up does nothing.
        #expect(review.reduce(.allowTapped(challenge: challenge, .allowOnce)).isEmpty)
        let sent = review.reduce(.authenticated(challenge: challenge, .allowOnce, .authenticated))
        #expect(sent == [.complete(UIUnlockCompletion(
            challengeID: challenge, codeHash: Self.hash, decision: .allowOnce, outcome: .authenticated))])
        #expect(review.reduce(.completeReplied(challenge: challenge, .success(.allowedOnce))) == [.list])
        #expect(review.phase == .answered(codeHash: Self.hash, .allowedOnce))
        // A late duplicate reply changes nothing.
        #expect(review.reduce(.completeReplied(challenge: challenge, .success(.allowedOnce))).isEmpty)
    }

    /// Review item 7: a tap names the challenge its sheet showed; once the
    /// ask is bound again, the old tap answers nothing.
    @Test func aTapForAReviewThatWasBoundAgainDoesNothing() {
        let old = UUID()
        var review = Self.reviewing(Self.bundle(challenge: old))
        _ = review.reduce(.closeTapped)
        _ = review.reduce(.openTapped(codeHash: Self.hash))
        let fresh = UUID()
        _ = review.reduce(.bindReplied(codeHash: Self.hash, .success(Self.bundle(challenge: fresh))))
        #expect(review.reduce(.allowTapped(challenge: old, .alwaysAllow)).isEmpty)
        #expect(review.isBusy == false)
        #expect(review.reduce(.allowTapped(challenge: fresh, .allowOnce)).count == 1)
    }

    /// Review item 4, the menu bar's half: a prompt that did not pass is
    /// reported to rvd (which grants nothing and records it), and the sheet
    /// binds again for another try.
    @Test func aPromptThatDidNotPassIsReportedAndTheSheetBindsAgain() {
        for outcome in [UIAuthenticationOutcome.cancelled, .failed, .unavailable, .timedOut, .invalidated] {
            let challenge = UUID()
            var review = Self.reviewing(Self.bundle(challenge: challenge))
            _ = review.reduce(.allowTapped(challenge: challenge, .alwaysAllow))
            #expect(review.reduce(.authenticated(challenge: challenge, .alwaysAllow, outcome)) == [.complete(
                UIUnlockCompletion(challengeID: challenge, codeHash: Self.hash, decision: .alwaysAllow, outcome: outcome))])
            #expect(review.notice?.contains("Nothing was allowed") == true
                || review.notice?.contains("aren't available") == true)
            #expect(review.reduce(.completeReplied(challenge: challenge, .success(.declined)))
                == [.bind(codeHash: Self.hash), .list])
            #expect(review.phase == .binding(codeHash: Self.hash))
            let again = UUID()
            #expect(review.reduce(.bindReplied(codeHash: Self.hash, .success(Self.bundle(challenge: again)))).isEmpty)
            #expect(review.onSheet?.challenge.challengeID == again)
        }
    }

    @Test func aLockoutSaysSoAndKeepsTheSheetWithAllowOff() {
        let challenge = UUID()
        var review = Self.reviewing(Self.bundle(challenge: challenge))
        _ = review.reduce(.allowTapped(challenge: challenge, .allowOnce))
        _ = review.reduce(.authenticated(challenge: challenge, .allowOnce, .cancelled))
        #expect(review.reduce(.completeReplied(challenge: challenge, .success(.lockedOut)))
            == [.bind(codeHash: Self.hash), .list])
        #expect(review.notice == UnlockSheet.lockedOutLine)
        let again = UUID()
        _ = review.reduce(.bindReplied(
            codeHash: Self.hash, .success(Self.bundle(Self.item(status: .lockedOut), challenge: again))))
        #expect(review.reduce(.allowTapped(challenge: again, .allowOnce)).isEmpty)
    }

    @Test func aStrayAuthenticationOrReplyIsIgnored() {
        let challenge = UUID()
        var review = Self.reviewing(Self.bundle(challenge: challenge))
        _ = review.reduce(.allowTapped(challenge: challenge, .allowOnce))
        // Another challenge, or the other answer than the one asked.
        #expect(review.reduce(.authenticated(challenge: UUID(), .allowOnce, .authenticated)).isEmpty)
        #expect(review.reduce(.authenticated(challenge: challenge, .alwaysAllow, .authenticated)).isEmpty)
        #expect(review.reduce(.completeReplied(challenge: challenge, .success(.allowedOnce))).isEmpty)
    }

    @Test func aRefusedAnswerNeedsAFreshReview() {
        let challenge = UUID()
        var review = Self.reviewing(Self.bundle(challenge: challenge))
        _ = review.reduce(.allowTapped(challenge: challenge, .allowOnce))
        _ = review.reduce(.authenticated(challenge: challenge, .allowOnce, .authenticated))
        #expect(review.reduce(.completeReplied(challenge: challenge, .failure(.refused))) == [.list])
        #expect(review.phase == .idle)
        #expect(review.reduce(.allowTapped(challenge: challenge, .allowOnce)).isEmpty)
    }

    @Test func denySendsNoAnswerAndHidesTheAskUntilRvdDropsIt() {
        var review = Self.reviewing(Self.bundle())
        _ = review.reduce(Self.listed([Self.row()]))
        #expect(review.reduce(.denyTapped) == [.release(codeHash: Self.hash)])
        #expect(review.phase == .idle)
        #expect(review.waiting.isEmpty)
        _ = review.reduce(Self.listed([]))
        #expect(review.dismissed.isEmpty)
    }

    @Test func aBindForAnotherAskThanTheOneOpenedIsRefused() {
        var review = UnlockReview()
        _ = review.reduce(.openTapped(codeHash: Self.hash))
        let other = Self.bundle(Self.item(hash: String(repeating: "cd", count: 32)))
        #expect(review.reduce(.bindReplied(codeHash: Self.hash, .success(other))) == [.list])
        #expect(review.onSheet == nil)
    }

    @Test func anAskAnsweredElsewhereLeavesTheSheetButOneBeyondTheCapDoesNot() {
        var capped = Self.reviewing(Self.bundle())
        _ = capped.reduce(Self.listed([Self.row(hash: String(repeating: "cd", count: 32))], omitted: 4))
        #expect(capped.onSheet != nil)
        var review = Self.reviewing(Self.bundle())
        _ = review.reduce(Self.listed([]))
        #expect(review.phase == .idle)
        #expect(review.notice != nil)
    }

    /// Review item 3: a menu bar rvd refuses (an unpinned build) or cannot
    /// reach asks less and less often, and every 4 s again once it answers.
    @Test func thePollBacksOffWhileRvdRefusesAndRecoversWhenItAnswers() {
        var review = UnlockReview()
        #expect(review.pollDelay == .seconds(4))
        var delays: [Duration] = []
        for _ in 0..<9 {
            _ = review.reduce(.listReplied(.failure(.unreachable)))
            delays.append(review.pollDelay)
        }
        #expect(delays.prefix(4) == [.seconds(8), .seconds(16), .seconds(32), .seconds(64)])
        #expect(delays.last == .seconds(300))
        #expect(delays == delays.sorted())
        _ = review.reduce(Self.listed([Self.row()]))
        #expect(review.pollDelay == .seconds(4))
        // The list carries rows only; the words are worked out here.
        let asks = GlanceUnlockAsk.asks(from: review.waiting)
        #expect(asks[Self.hash]?.checkWords == "orchid · rocket · crane")
    }

    // MARK: The banner

    /// Review blocker 1(a): no banner action starts Touch ID. "Allow once…"
    /// and a tap only open the sheet; the bind shows it and asks nothing.
    @Test func allowOnceOnABannerOnlyOpensTheSheet() async {
        let route = UnlockNoticeAction.route(actionID: UnlockNoticeAction.allowOnce, codeHash: Self.hash)
        #expect(route == UnlockNoticeAction.Route(codeHash: Self.hash))
        #expect(UnlockNoticeAction.route(actionID: UnlockNoticeAction.openBanner, codeHash: Self.hash) == route)
        #expect(UnlockNoticeAction.route(actionID: UnlockNoticeAction.dismissBanner, codeHash: Self.hash) == nil)
        #expect(UnlockNoticeAction.route(actionID: UnlockNoticeAction.allowOnce, codeHash: "a7c835") == nil)
        #expect(UnlockNoticeAction.route(actionID: UnlockNoticeAction.allowOnce, codeHash: nil) == nil)

        // Driven end to end through the runner: the sheet is up, and no
        // prompt was asked and no answer sent.
        let bridge = FakeBridge(bundle: Self.bundle())
        let authenticator = CountingAuthenticator(.authenticated)
        var review = UnlockReview()
        await UnlockReviewRunner.send(
            .openTapped(codeHash: Self.hash), to: &review, bridge: bridge, authenticator: authenticator)
        #expect(review.onSheet == bridge.bundle)
        #expect(authenticator.reasons.withLock { $0 }.isEmpty)
        #expect(bridge.completions.withLock { $0 }.isEmpty)

        // Only the tap on the sheet asks, and only its yes is an answer.
        let challenge = bridge.bundle.challenge.challengeID
        await UnlockReviewRunner.send(
            .allowTapped(challenge: challenge, .allowOnce), to: &review, bridge: bridge, authenticator: authenticator)
        #expect(authenticator.reasons.withLock { $0 }.count == 1)
        #expect(bridge.completions.withLock { $0.map(\.outcome) } == [.authenticated])
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

    init(bundle: UIUnlockChallengeBundleDTO) {
        self.bundle = bundle
    }

    func list() async throws -> UIUnlockListDTO {
        UIUnlockListDTO(items: [UIUnlockSummaryDTO(
            codeHash: bundle.item.codeHash, code: bundle.item.code, host: bundle.item.host,
            advisoryExpiresWall: bundle.item.advisoryExpiresWall)])
    }
    func bind(codeHash: String) async throws -> UIUnlockChallengeBundleDTO { bundle }
    func complete(_ completion: UIUnlockCompletion) async throws -> UIUnlockStatusDTO {
        completions.withLock { $0.append(completion) }
        return UIUnlockStatusDTO(codeHash: completion.codeHash, status: .allowedOnce)
    }
    func release(codeHash: String) async throws -> UIUnlockStatusDTO {
        UIUnlockStatusDTO(codeHash: codeHash, status: .waiting)
    }
}

final class CountingAuthenticator: UnlockAuthenticator {
    let outcome: UIAuthenticationOutcome
    /// Every prompt asked, by its reason.
    let reasons = Mutex<[String]>([])

    init(_ outcome: UIAuthenticationOutcome) {
        self.outcome = outcome
    }

    func authenticate(reason: String) async -> UIAuthenticationOutcome {
        reasons.withLock { $0.append(reason) }
        return outcome
    }
}

import Foundation
import Testing
import RVDomain
import RVEngine
import RVHistory
import RVIPC
@testable import RVIsolation
import RVPolicy
@testable import RVService
import Synchronization

/// K2: the menu bar answers a stop's allow-once code after Touch ID. rvd
/// grants exactly what the terminal would (one grant, or one exact-command
/// allowlist entry plus the grant), writes the same audit rows first, and
/// only for the pinned operator UI, once per code, before the code expires.
@Suite("Unlock review (K2)")
struct UnlockReviewCeremonyTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let pushRule = RuleID(pack: .coreGit, pattern: "push-force")

    final class Clock: Sendable {
        private let value: Mutex<Date>
        init(_ now: Date) { value = Mutex(now) }
        var now: Date { value.withLock { $0 } }
        func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private struct Rig {
        let runtime: ServiceRuntime
        let ceremony: UnlockReviewCeremonyService
        let store: AllowOnceStore
        let home: HomeDirectory
        let homeURL: URL
        let clock: Clock
        let ui = AuthenticatedOperatorUIConnectionID()

        var configDirectory: URL { RVPolicyPaths.configDirectory(home: home) }
    }

    /// `recordAudit` nil writes real rows to the rig's audit log; otherwise
    /// a stand-in answers whether the row "landed".
    private func rig(recordAudit: Bool? = nil) async throws -> Rig {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let store = AllowOnceStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        let clock = Clock(start)
        let runtime = ServiceRuntime(
            snapshots: nil, catalog: nil, home: home, allowOnce: store, allowOnceDirectory: nil,
            idleExitSeconds: IdleWatchdog.defaultSeconds, log: nil, analytics: nil, clock: { clock.now },
            pendingApprovals: .automatic, ceremonies: WorkspaceOperatorCeremonyService(),
            hookBudget: testHookBudget)
        var recorder = UnlockReviewRecorder.live(home: home)
        if let recordAudit {
            recorder.audit = { _, _ in recordAudit }
        }
        let ceremony = UnlockReviewCeremonyService(
            allowOnce: store, grants: await runtime.grants, recorder: recorder, clock: { clock.now })
        return Rig(
            runtime: runtime, ceremony: ceremony, store: store, home: home, homeURL: homeURL, clock: clock)
    }

    /// rvd's hook path issuing a deny code, as `HookDoor` does.
    @discardableResult
    private func stop(
        _ command: String, _ rig: Rig, says: String? = "Force-push my rebased branch"
    ) async throws -> String {
        let shell = ShellCommand(rawValue: command)
        let code = try #require(await rig.store.mintFromDeny(
            matchingView: Normalize.matchingView(of: shell), cwd: wd("/tmp/ws"), ruleID: pushRule, now: rig.clock.now,
            maskedSegments: Normalize.maskedSegments(of: shell), invocationPrefix: Normalize.invocationPrefix(of: shell),
            invocationDisplay: Normalize.invocationDisplay(of: shell), rawCommand: command,
            stop: AllowOnceStopContext(asker: .claude, agentSays: says))?.code)
        return code.rawValue
    }

    private func evaluate(_ command: String, _ rig: Rig) async -> Bool {
        let decision = await rig.runtime.evaluate(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: wd("/tmp/ws")
        ).result.decision
        if case .allow = decision { return true }
        return false
    }

    private func answer(
        _ bundle: UIUnlockChallengeBundleDTO, _ rig: Rig, _ decision: UIUnlockDecision = .allowOnce,
        outcome: UIAuthenticationOutcome = .authenticated, ui: AuthenticatedOperatorUIConnectionID? = nil
    ) async throws(UnlockReviewError) -> UIUnlockStatus {
        try await rig.ceremony.complete(
            UIUnlockCompletion(
                challengeID: bundle.challenge.challengeID, codeHash: bundle.challenge.codeHash,
                decision: decision, outcome: outcome),
            uiConnection: ui ?? rig.ui, context: peerOperatorUIContext())
    }

    private func auditText(_ rig: Rig) throws -> String {
        try String(contentsOf: AuditLog.fileURL(configDirectory: rig.configDirectory), encoding: .utf8)
    }

    // MARK: What the sheet is shown

    @Test func theListShowsTheWholeStoppedCommandTheWordsAndTheAgentsOwnLine() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let long = "git push --force origin " + String(repeating: "feature-", count: 30)
        let code = try await stop(long, rig)
        let items = await rig.ceremony.list().items
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.code == code)
        #expect(item.codeHash == sha256Hex(code))
        #expect(item.command == long)
        #expect(item.host == .claude)
        #expect(item.agentSays == "Force-push my rebased branch")
        #expect(item.checkWords == CheckWords.words(for: try #require(AllowOnceUnlockCode(validating: code))))
        #expect(item.promptText == "allow once \"\(long)\" in /tmp/ws (rule core.git:push-force, code \(code))")
        #expect(item.status == .waiting)
    }

    @Test func aPreArmedCodeIsTheOwnersOwnAndNeverAnAsk() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        _ = try await rig.store.mintPreArmed(
            matchingView: MatchingView("git reset --hard"), cwd: wd("/tmp/ws"), now: start,
            rawCommand: "git reset --hard")
        #expect(await rig.ceremony.list().items.isEmpty)
    }

    @Test func aCommandTooLongForThePromptIsShownButCannotBeApproved() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        try await stop("git push --force origin " + String(repeating: "b", count: 400), rig)
        let bundle = try await rig.ceremony.bind(codeHash: try #require(await rig.ceremony.list().items.first).codeHash,
                                                 uiConnection: rig.ui)
        #expect(bundle.item.approvable == false)
        await #expect(throws: UnlockReviewError.notShowable) { try await answer(bundle, rig) }
    }

    // MARK: Allow once

    @Test func allowOncePlantsTheTerminalsGrantAndTheRetryRunsOnce() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        #expect(bundle.item.status == .awaitingAuthentication)
        #expect(try await answer(bundle, rig) == .allowedOnce)
        #expect(await evaluate("git push --force origin main", rig))
        #expect(await evaluate("git push --force origin main", rig) == false)
        // `rv wait` sees the answer in the ledger.
        let row = await rig.store.list(now: rig.clock.now).first { $0.codeHash == sha256Hex(code) }
        #expect(row?.kind == .granted)
        // The terminal's audit row, from the operator UI.
        let audit = try auditText(rig)
        #expect(audit.contains("redeem allow-once code"))
        #expect(audit.contains("operatorUI"))
        #expect(audit.contains("origin main") == false)
        #expect(await rig.ceremony.list().items.isEmpty)
    }

    @Test func aReplayedAnswerAndASecondReviewGrantNothingMore() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        #expect(try await answer(bundle, rig) == .allowedOnce)
        await #expect(throws: UnlockReviewError.unknownCode) { try await answer(bundle, rig) }
        await #expect(throws: UnlockReviewError.unknownCode) {
            try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        }
        #expect(await evaluate("git push --force origin main", rig))
        #expect(await evaluate("git push --force origin main", rig) == false)
    }

    @Test func noAuthenticationGrantsNothingAndSpendsTheChallenge() async throws {
        for outcome in [UIAuthenticationOutcome.cancelled, .failed, .unavailable, .timedOut, .invalidated] {
            let rig = try await rig()
            defer { try? FileManager.default.removeItem(at: rig.homeURL) }
            let code = try await stop("git push --force origin main", rig)
            let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
            await #expect(throws: UnlockReviewError.authenticationRequired) {
                try await answer(bundle, rig, outcome: outcome)
            }
            await #expect(throws: UnlockReviewError.unknownCode) { try await answer(bundle, rig) }
            #expect(await evaluate("git push --force origin main", rig) == false)
            // The code stays live: a new review can still be opened.
            let again = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
            #expect(again.challenge.challengeID != bundle.challenge.challengeID)
        }
    }

    @Test func anotherConnectionCanNeitherTakeOverNorAnswerAReview() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        let other = AuthenticatedOperatorUIConnectionID()
        await #expect(throws: UnlockReviewError.notReviewable) {
            try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: other)
        }
        await #expect(throws: UnlockReviewError.notReviewable) { try await answer(bundle, rig, ui: other) }
        // Its own connection still can.
        #expect(try await answer(bundle, rig) == .allowedOnce)
    }

    @Test func aDeadConnectionsReviewDiesAndTheCodeStaysLive() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        await rig.ceremony.uiConnectionLost(rig.ui)
        await #expect(throws: UnlockReviewError.unknownCode) { try await answer(bundle, rig) }
        #expect(await rig.ceremony.list().items.count == 1)
    }

    @Test func aStaleReviewOrAnExpiredCodeIsRefused() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        rig.clock.advance(by: UnlockReviewLimits.challengeLifetime + 1)
        await #expect(throws: UnlockReviewError.unknownCode) { try await answer(bundle, rig) }
        // The deny code itself lives 15 minutes.
        rig.clock.advance(by: 15 * 60)
        #expect(await rig.ceremony.list().items.isEmpty)
        await #expect(throws: UnlockReviewError.unknownCode) {
            try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        }
        #expect(await evaluate("git push --force origin main", rig) == false)
    }

    @Test func releaseLeavesTheCommandStoppedAndTheCodeLive() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        #expect(try await rig.ceremony.release(codeHash: sha256Hex(code), uiConnection: rig.ui) == .waiting)
        await #expect(throws: UnlockReviewError.unknownCode) { try await answer(bundle, rig) }
        #expect(await evaluate("git push --force origin main", rig) == false)
        #expect(await rig.ceremony.list().items.first?.status == .waiting)
    }

    @Test func theTerminalAndTheMenuBarCanNeverBothSpendOneCode() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        // The terminal plants first, under the same per-code key.
        let pending = try #require(await rig.store.validatePending(code: code, now: start))
        #expect(await rig.runtime.grants.plant(
            fingerprint: GrantFingerprint(rawValue: pending.fingerprint), cwd: pending.row.cwd,
            codeHash: CodeHash(rawValue: "tty:\(sha256Hex(code))"), now: start,
            payloadContentDigest: pending.payloadDigest.map(ContentPayloadDigest.init(rawValue:))) == .planted)
        #expect(try await answer(bundle, rig) == .alreadyAnswered)
        #expect(await evaluate("git push --force origin main", rig))
        #expect(await evaluate("git push --force origin main", rig) == false)
    }

    @Test func anApprovalThatCannotBeAuditedGrantsNothing() async throws {
        let rig = try await rig(recordAudit: false)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        await #expect(throws: UnlockReviewError.notRecorded) { try await answer(bundle, rig, .alwaysAllow) }
        #expect(await evaluate("git push --force origin main", rig) == false)
        let entries = AllowlistStore(baseDirectory: rig.configDirectory).loadForValidate(workspacePath: nil)
        #expect(entries == .missing)
    }

    // MARK: Always allow

    @Test func alwaysAllowWritesTheExactEntryTheCLIWritesAndNothingWider() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let command = "git push --force origin main"
        let code = try await stop(command, rig)
        let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
        #expect(try await answer(bundle, rig, .alwaysAllow) == .alwaysAllowed)
        guard case .ok(let entries) = AllowlistStore(baseDirectory: rig.configDirectory)
            .loadForValidate(workspacePath: nil)
        else {
            Issue.record("always allow must write allowlist.toml")
            return
        }
        // What `rv allowlist add-command` builds for the same text.
        let shell = ShellCommand(rawValue: command)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.selector == .exactCommand(EvaluationWorld.matchingView(of: shell)))
        #expect(entry.maskedPayloadDigest == maskedPayloadContentDigest(Normalize.maskedSegments(of: shell)))
        #expect(entry.invocationDigest == maskedPayloadContentDigest(Normalize.invocationPrefix(of: shell)))
        #expect(entry.expiresAt == nil)
        // Both terminal audit rows, then the allowlist's own change row.
        let audit = try auditText(rig)
        #expect(audit.contains("add allowlist exception for an exact command"))
        #expect(audit.contains("redeem allow-once code"))
        #expect(audit.contains(UnlockReviewLimits.authorization))
        // The once grant, then the entry: the same command keeps running,
        // a different force-push does not.
        #expect(await evaluate(command, rig))
        #expect(await evaluate(command, rig))
        #expect(await evaluate("git push --force origin release", rig) == false)
    }

    @Test func theAuditSummariesAreTheTerminalsInItsOrder() {
        #expect(UnlockReviewRules.auditSummaries(.allowOnce) == ["redeem allow-once code"])
        #expect(UnlockReviewRules.auditSummaries(.alwaysAllow)
            == ["add allowlist exception for an exact command", "redeem allow-once code"])
    }

    // MARK: Who may ask

    private func registered(_ context: AuthenticatedRequestContext) async throws -> LiveOperatorUISessionRegistry {
        let sessions = LiveOperatorUISessionRegistry()
        _ = try await sessions.register(peer: try #require(context.peer))
        return sessions
    }

    @Test func onlyThePinnedOperatorUIRunningAsTheOwnerIsAnswered() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        try await stop("git push --force origin main", rig)
        let ui = peerOperatorUIContext()
        let sessions = try await registered(ui)
        func reply(
            _ context: AuthenticatedRequestContext, handshakeOK: Bool = true, discoveryOnly: Bool = false,
            owner: UInt32 = 501
        ) async -> IPCResult {
            await UnlockReviewBridge.reply(
                .unlockList, context: context, handshakeOK: handshakeOK, discoveryOnly: discoveryOnly,
                sessions: sessions, ceremony: rig.ceremony, ownerUserID: owner)
        }
        guard case .uiUnlockList(let list) = await reply(ui) else {
            Issue.record("the registered operator UI must be answered")
            return
        }
        #expect(list.items.count == 1)
        // A coding agent's process is at best a role-less same-user peer,
        // or drives the pinned CLI: neither is the operator UI.
        for context in [peerHookContext(), peerCliContext(), peerServiceContext(), AuthenticatedRequestContext.unauthenticated] {
            #expect(await reply(context) == .error(.authorizationDenied))
        }
        #expect(await reply(ui, owner: 502) == .error(.authorizationDenied))
        #expect(await reply(ui, handshakeOK: false) == .error(.authorizationDenied))
        #expect(await reply(ui, discoveryOnly: true) == .error(.authorizationDenied))
        // An operator UI connection that never registered.
        #expect(await UnlockReviewBridge.reply(
            .unlockList, context: peerOperatorUIContext(), handshakeOK: true, discoveryOnly: false,
            sessions: sessions, ceremony: rig.ceremony, ownerUserID: 501) == .error(.authorizationDenied))
    }

    @Test func theBridgeAnswersOnceThenRefusesTheReplayOpaquely() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let ui = peerOperatorUIContext()
        let sessions = try await registered(ui)
        func send(_ request: UIUnlockBridgeRequest) async -> IPCResult {
            await UnlockReviewBridge.reply(
                request, context: ui, handshakeOK: true, discoveryOnly: false, sessions: sessions,
                ceremony: rig.ceremony, ownerUserID: 501)
        }
        guard case .uiUnlockChallengeBundle(let bundle) = await send(.unlockBind(codeHash: sha256Hex(code))) else {
            Issue.record("bind must answer a bundle")
            return
        }
        let completion = UIUnlockCompletion(
            challengeID: bundle.challenge.challengeID, codeHash: sha256Hex(code), decision: .allowOnce,
            outcome: .authenticated)
        #expect(await send(.unlockComplete(completion))
            == .uiUnlockStatus(UIUnlockStatusDTO(codeHash: sha256Hex(code), status: .allowedOnce)))
        #expect(await send(.unlockComplete(completion)) == .error(.authorizationDenied))
        #expect(await send(.unlockBind(codeHash: String(repeating: "0", count: 64))) == .error(.authorizationDenied))
    }

    // MARK: From the hook

    @Test func aClaudeStopCarriesItsAgentAndItsOwnDescriptionToTheList() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let stdin = """
        {"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp/ws","session_id":"s",\
        "tool_input":{"command":"git reset --hard","description":"Throw away my scratch edits"}}
        """
        let hook = IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .claude, stdin: stdin)))
        guard case .hookEvaluate(let denied) = await rig.runtime.dispatch(hook, context: peerHookContext()).result
        else {
            Issue.record("the hook must answer")
            return
        }
        let match = try #require(denied.stdout.firstMatch(of: /rv allow-once ([0-9a-f]{6})/))
        let item = try #require(await rig.ceremony.list().items.first)
        #expect(item.code == String(match.1))
        #expect(item.host == .claude)
        #expect(item.command == "git reset --hard")
        #expect(item.agentSays == "Throw away my scratch edits")
        // The agent's words never reach the stop text.
        #expect(denied.stdout.contains("scratch edits") == false)
    }
}

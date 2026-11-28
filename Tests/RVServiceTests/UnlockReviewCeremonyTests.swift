import Foundation
import Testing
import RVDomain
import RVEngine
import RVFileStore
import RVGlance
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
        /// The owner-check lockout the terminal path shares.
        let presence: OwnerPresence
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
            recorder.audit = { _, _, _, _ in recordAudit }
        }
        let presence = OwnerPresence(authenticator: nil, clock: { clock.now })
        let ceremony = UnlockReviewCeremonyService(
            allowOnce: store, grants: await runtime.grants, recorder: recorder, presence: .live(presence),
            clock: { clock.now })
        return Rig(
            runtime: runtime, ceremony: ceremony, store: store, home: home, homeURL: homeURL, clock: clock,
            presence: presence)
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

    private func bind(_ code: String, _ rig: Rig) async throws(UnlockReviewError) -> UIUnlockChallengeBundleDTO {
        try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
    }

    private func allowlist(_ rig: Rig) -> [AllowlistEntry] {
        guard case .ok(let entries) = AllowlistStore(baseDirectory: rig.configDirectory)
            .loadForValidate(workspacePath: nil) else { return [] }
        return entries
    }

    // MARK: What the sheet is shown

    @Test func theSheetShowsTheWholeStoppedCommandTheWordsAndTheAgentsOwnLine() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let long = "git push --force origin " + String(repeating: "feature-", count: 30)
        let code = try await stop(long, rig)
        let rows = await rig.ceremony.list()
        let row = try #require(rows.items.first)
        #expect(rows.items.count == 1 && rows.omitted == 0)
        #expect(row == UIUnlockSummaryDTO(
            codeHash: sha256Hex(code), code: code, host: .claude, advisoryExpiresWall: row.advisoryExpiresWall))
        let item = try await bind(code, rig).item
        #expect(item.code == code)
        #expect(item.codeHash == sha256Hex(code))
        #expect(item.command == long)
        #expect(item.host == .claude)
        #expect(item.agentSays == "Force-push my rebased branch")
        #expect(item.checkWords == CheckWords.words(for: try #require(AllowOnceUnlockCode(validating: code))))
        #expect(item.promptText == "allow once \"\(long)\" in /tmp/ws (rule core.git:push-force, code \(code))")
        #expect(item.status == .awaitingAuthentication)
    }

    /// Review item 8: rvd words the plain line from its own raw copy of
    /// the command, then escapes it like every other field.
    @Test func thePlainLineIsWordedFromTheRawCommand() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let raw = "git\treset --hard"
        let code = try await stop(raw, rig)
        let item = try await bind(code, rig).item
        let fromRaw = PlainTemplate.line(for: PlainRequest(
            host: .claude, tool: .bash, text: raw, outcome: .stopped, rule: pushRule.rawValue)).text
        #expect(item.effect == DisplayedText.approvalField(fromRaw))
        #expect(item.effect.isEmpty == false)
        #expect(item.command == DisplayedText.approvalField(raw))
    }

    /// Review item 3: a flood of stops is a small reply: at most the cap,
    /// oldest first, rows without any command text.
    @Test func theListIsCappedAndCarriesNoCommandText() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        for index in 0..<(UnlockReviewLimits.listCap + 5) {
            try await stop("git push --force origin branch-\(index)", rig)
            rig.clock.advance(by: 1)
        }
        let list = await rig.ceremony.list()
        #expect(list.items.count == UnlockReviewLimits.listCap)
        #expect(list.omitted == 5)
        let wire = try #require(String(data: IPCJSON.encode(list), encoding: .utf8))
        #expect(wire.contains("branch-") == false)
        #expect(wire.contains("/tmp/ws") == false)
        #expect(list.items.map(\.advisoryExpiresWall) == list.items.map(\.advisoryExpiresWall).sorted())
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
        let code = try await stop("git push --force origin " + String(repeating: "b", count: 400), rig)
        let bundle = try await bind(code, rig)
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

    /// Review item 4: a declined prompt grants nothing, spends the
    /// challenge, and writes an `approved: false` owner-action row.
    @Test func aDeclinedPromptGrantsNothingIsAuditedAndSpendsTheChallenge() async throws {
        for outcome in [UIAuthenticationOutcome.cancelled, .failed, .unavailable, .timedOut, .invalidated] {
            let rig = try await rig()
            defer { try? FileManager.default.removeItem(at: rig.homeURL) }
            let code = try await stop("git push --force origin main", rig)
            let bundle = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
            #expect(try await answer(bundle, rig, outcome: outcome) == .declined)
            await #expect(throws: UnlockReviewError.unknownCode) { try await answer(bundle, rig) }
            let audit = try auditText(rig)
            #expect(audit.contains("redeem allow-once code"))
            #expect(audit.contains("\"outcome\":\"\(outcome.rawValue)\""))
            #expect(audit.contains("\"decision\":\"denied\""))
            #expect(await evaluate("git push --force origin main", rig) == false)
            // The code stays live: a new review can still be opened.
            let again = try await rig.ceremony.bind(codeHash: sha256Hex(code), uiConnection: rig.ui)
            #expect(again.challenge.challengeID != bundle.challenge.challengeID)
        }
    }

    /// Review item 4: the terminal's lockout. Five declines in ten minutes
    /// lock owner checks for ten minutes, for the menu bar and the
    /// terminal alike; a prompt that never appeared is no strike.
    @Test func fiveDeclinesLockOwnerChecksForTenMinutes() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        for _ in 0..<OwnerPresence.maxFailures {
            #expect(try await answer(try await bind(code, rig), rig, outcome: .unavailable) == .declined)
        }
        #expect(await rig.presence.isLockedOut() == false)
        var statuses: [UIUnlockStatus] = []
        for _ in 0..<OwnerPresence.maxFailures {
            statuses.append(try await answer(try await bind(code, rig), rig, outcome: .cancelled))
        }
        #expect(statuses == Array(repeating: .declined, count: OwnerPresence.maxFailures - 1) + [.lockedOut])
        #expect(await rig.presence.isLockedOut())
        // The sheet says so, and even a passed prompt grants nothing.
        let locked = try await bind(code, rig)
        #expect(locked.item.status == .lockedOut)
        #expect(try await answer(locked, rig) == .lockedOut)
        #expect(await evaluate("git push --force origin main", rig) == false)
        #expect(try auditText(rig).contains("\"outcome\":\"lockedOut\""))
        // Ten minutes on, the code (15 minutes) can still be allowed.
        rig.clock.advance(by: OwnerPresence.lockout + 1)
        #expect(try await answer(try await bind(code, rig), rig) == .allowedOnce)
        #expect(await evaluate("git push --force origin main", rig))
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
        #expect(try await bind(code, rig).item.status == .awaitingAuthentication)
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

    /// Review item 2: no room for the once grant, but the entry is
    /// written: the answer is Always allowed, which is the truth.
    @Test func alwaysAllowWithNoRoomForTheOnceGrantStillSaysAlwaysAllowed() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let command = "git push --force origin main"
        let code = try await stop(command, rig)
        for index in 0..<EphemeralAllowOnceTable.maxGrants {
            _ = await rig.runtime.grants.plant(
                fingerprint: GrantFingerprint(rawValue: "filler-\(index)"), cwd: wd("/tmp/other"),
                codeHash: CodeHash(rawValue: "filler-\(index)"), now: start)
        }
        #expect(try await answer(try await bind(code, rig), rig, .alwaysAllow) == .alwaysAllowed)
        #expect(allowlist(rig).count == 1)
        #expect(await evaluate(command, rig))
        // A lone once with no room still says nothing was allowed.
        let other = try await stop("git push --force origin release", rig)
        await #expect(throws: UnlockReviewError.notReviewable) { try await answer(try await bind(other, rig), rig) }
    }

    /// Review item 5: an expired or legacy entry for the same command can't
    /// stand in for the answer: it is replaced, and the command runs.
    @Test func alwaysAllowReplacesAnExpiredOrLegacyEntryForTheSameCommand() async throws {
        let command = "git push --force origin main"
        let shell = ShellCommand(rawValue: command)
        let selector = AllowlistSelector.exactCommand(EvaluationWorld.matchingView(of: shell))
        let stale = [
            AllowlistEntry(
                selector: selector, reason: "old", addedAt: start.addingTimeInterval(-7200),
                expiresAt: start.addingTimeInterval(-3600),
                maskedPayloadDigest: maskedPayloadContentDigest(Normalize.maskedSegments(of: shell)),
                invocationDigest: maskedPayloadContentDigest(Normalize.invocationPrefix(of: shell))),
            AllowlistEntry(selector: selector, reason: "legacy", addedAt: start.addingTimeInterval(-7200)),
        ]
        for old in stale {
            let rig = try await rig()
            defer { try? FileManager.default.removeItem(at: rig.homeURL) }
            try AllowlistStore(baseDirectory: rig.configDirectory).pin(old)
            let code = try await stop(command, rig)
            #expect(try await answer(try await bind(code, rig), rig, .alwaysAllow) == .alwaysAllowed)
            let entries = allowlist(rig)
            #expect(entries.count == 1)
            #expect(entries.first?.expiresAt == nil)
            #expect(entries.first?.maskedPayloadDigest != nil && entries.first?.invocationDigest != nil)
            #expect(await evaluate(command, rig))
            #expect(await evaluate(command, rig))
        }
    }

    /// Review item 6: another process holding the ledger lock delays the
    /// projection, it doesn't drop it, so `rv wait` still sees the grant.
    @Test func theLedgerFlipWaitsOutABriefLockInsteadOfSkippingIt() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let code = try await stop("git push --force origin main", rig)
        let bundle = try await bind(code, rig)
        let lockURL = RVPolicyPaths.allowOnceLockFile(inConfigDir: rig.configDirectory)
        let held = Mutex(false)
        let holder = Thread {
            _ = try? ExclusiveFileLock.withLock(at: lockURL) {
                held.withLock { $0 = true }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        holder.start()
        while held.withLock({ $0 }) == false { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try await answer(bundle, rig) == .allowedOnce)
        let row = await rig.store.list(now: rig.clock.now).first { $0.codeHash == sha256Hex(code) }
        #expect(row?.kind == .granted)
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
        let match = try #require(denied.stdout.firstMatch(of: /rv (?:allow-once|unlock) ([0-9a-f]{6})/))
        let item = try await bind(String(match.1), rig).item
        #expect(item.code == String(match.1))
        #expect(item.host == .claude)
        #expect(item.command == "git reset --hard")
        #expect(item.agentSays == "Throw away my scratch edits")
        // The agent's words never reach the stop text.
        #expect(denied.stdout.contains("scratch edits") == false)
    }
}

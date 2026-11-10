import Foundation
import Testing
import RVDomain
import RVEngine
import RVHistory
import RVHooks
import RVIPC
@testable import RVIsolation
import RVPolicy
@testable import RVService
import Synchronization

/// `rv allow-once <code>` on a macOS install with no peer-trust manifest:
/// rvd shows the owner prompt itself, with its own description of the code
/// it issued, through the same single slot, timeout and lockout as owner
/// actions. The caller's role confers nothing. The prompt is always the
/// injected fake: no test reaches LocalAuthentication.
@Suite("Allow-once owner prompt in rvd")
struct AllowOnceOwnerPromptTests {
    typealias FakeAuthenticator = OwnerPresenceTests.FakeAuthenticator
    typealias FakeChecker = OwnerPresenceTests.FakeChecker

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let pushRule = RuleID(pack: .coreGit, pattern: "push-force")

    private struct Rig: Sendable {
        let runtime: ServiceRuntime
        let store: AllowOnceStore
        let home: HomeDirectory
        let homeURL: URL
    }

    /// `prompt` nil is Linux: no LocalAuthentication, the login password
    /// ("secret") is the owner check.
    private func rig(
        _ prompt: FakeAuthenticator?,
        promptTimeout: Duration = OwnerPresence.defaultPromptTimeout,
        clock: TestClock? = nil
    ) throws -> Rig {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let clock = clock ?? TestClock(now)
        let runtime = ServiceRuntime(
            snapshots: nil, catalog: nil, home: home, allowOnce: store, allowOnceDirectory: nil,
            idleExitSeconds: IdleWatchdog.defaultSeconds, log: nil, analytics: nil, clock: { clock.now },
            pendingApprovals: .automatic, ceremonies: WorkspaceOperatorCeremonyService(),
            ownerPresence: OwnerPresence(
                checker: FakeChecker(accepted: "secret"), authenticator: prompt, promptTimeout: promptTimeout))
        return Rig(runtime: runtime, store: store, home: home, homeURL: homeURL)
    }

    final class TestClock: Sendable {
        private let value: Mutex<Date>
        init(_ now: Date) { value = Mutex(now) }
        var now: Date { value.withLock { $0 } }
        func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    /// rvd's hook path issuing a deny code for `command`, plus the attest
    /// the genuine CLI would send for it.
    private func issue(
        _ command: String, store: AllowOnceStore, rule: RuleID? = nil
    ) async throws -> AttestTTYRedemptionParams {
        let shell = ShellCommand(rawValue: command)
        let view = Normalize.matchingView(of: shell)
        let masked = Normalize.maskedSegments(of: shell)
        let prefix = Normalize.invocationPrefix(of: shell)
        let code = try #require(await store.mintFromDeny(
            matchingView: view, cwd: wd("/tmp/ws"), ruleID: rule, now: now,
            maskedSegments: masked, invocationPrefix: prefix,
            invocationDisplay: Normalize.invocationDisplay(of: shell), rawCommand: command
        )?.code)
        // Read back from the pending row, as the CLI does.
        let pending = try #require(await store.validatePending(code: code.rawValue, now: now))
        return AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: pending.fingerprint),
            cwd: pending.row.cwd,
            codeHash: CodeHash(rawValue: sha256Hex(code.rawValue)),
            clientSemver: ProtocolVersion.serviceSemver,
            payloadDigest: pending.payloadDigest.map(ContentPayloadDigest.init(rawValue:)))
    }

    private func attest(
        _ params: AttestTTYRedemptionParams, _ rig: Rig,
        context: AuthenticatedRequestContext = OwnerPresenceTests.unroledXPCContext()
    ) async -> IPCResult {
        await rig.runtime.dispatch(IPCRequest(method: .attestTTYRedemption(params)), context: context).result
    }

    /// The code rvd issued for `params`, as the prompt names it.
    private func issuedCode(of params: AttestTTYRedemptionParams, _ rig: Rig) async throws -> String {
        try #require(await rig.store.issued(codeHash: params.codeHash.rawValue, now: now)).code.rawValue
    }

    private func evaluate(_ command: String, _ rig: Rig) async -> Decision {
        await rig.runtime.evaluate(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: wd("/tmp/ws")
        ).result.decision
    }

    private func isAllow(_ decision: Decision) -> Bool {
        if case .allow = decision { return true }
        return false
    }

    @Test func anUnroledInstallRedeemsThroughRvdsPromptNamingTheWholeCommand() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git push --force origin main", store: rig.store, rule: pushRule)
        let code = try await issuedCode(of: params, rig)
        guard case .attestTTYRedemption(let reply) = await attest(params, rig) else {
            Issue.record("the owner's approval must plant")
            return
        }
        #expect(reply.planted)
        #expect(reply.ownerCheck == nil)
        #expect(prompt.reasons.withLock { $0 }
            == ["allow once \"git push --force origin main\" in /tmp/ws (rule core.git:push-force, code \(code))"])
        #expect(isAllow(await evaluate("git push --force origin main", rig)))
        #expect(isAllow(await evaluate("git push --force origin main", rig)) == false)
    }

    @Test func theHookDenyCodeRedeemsEndToEndThroughRvdsPrompt() async throws {
        // Production path: the hook denies through rvd, the code in the
        // deny text is read back from the pending file the way the CLI
        // does, and rvd's own prompt (the injected fake) shows the exact
        // command the hook saw.
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let stdin = """
        {"toolName":"bash","cwd":"/tmp/ws","sessionId":"s","input":{"command":"sudo -u root git reset --hard"}}
        """
        let hook = IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: stdin)))
        guard case .hookEvaluate(let denied) = await rig.runtime.dispatch(hook, context: peerHookContext()).result
        else {
            Issue.record("the hook must answer")
            return
        }
        let match = try #require(denied.stdout.firstMatch(of: /rv allow-once ([0-9a-f]{6})/))
        let code = String(match.1)
        let pending = try #require(await rig.store.validatePending(code: code, now: now))
        let params = AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: pending.fingerprint), cwd: pending.row.cwd,
            codeHash: CodeHash(rawValue: sha256Hex(code)), clientSemver: ProtocolVersion.serviceSemver,
            payloadDigest: pending.payloadDigest.map(ContentPayloadDigest.init(rawValue:)))
        guard case .attestTTYRedemption(let reply) = await attest(params, rig) else {
            Issue.record("the owner's approval must plant")
            return
        }
        #expect(reply.planted)
        #expect(prompt.reasons.withLock { $0 }
            == ["allow once \"sudo -u root git reset --hard\" in /tmp/ws (rule core.git:reset-hard, code \(code))"])
        guard case .hookEvaluate(let allowed) = await rig.runtime.dispatch(hook, context: peerHookContext()).result
        else {
            Issue.record("the hook must answer")
            return
        }
        #expect(allowed.stdout.contains("rv allow-once") == false)
    }

    @Test func aCommandTooLongToShowIsRefusedWithoutAPrompt() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let long = "git push --force origin " + String(repeating: "b", count: 400)
        let params = try await issue(long, store: rig.store)
        guard case .attestTTYRedemption(let reply) = await attest(params, rig) else {
            Issue.record("an unshowable command must answer with the owner check")
            return
        }
        #expect(reply.planted == false)
        #expect(reply.notShowable == true)
        #expect(reply.ownerCheck?.outcome == .unavailable)
        #expect(prompt.promptCount == 0)
        #expect(isAllow(await evaluate(long, rig)) == false)
    }

    @Test func aDeclinedPromptPlantsNothing() async throws {
        let rig = try rig(FakeAuthenticator(approve: false))
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git push --force origin main", store: rig.store)
        guard case .attestTTYRedemption(let reply) = await attest(params, rig) else {
            Issue.record("a declined prompt must answer with the owner check")
            return
        }
        #expect(reply.planted == false)
        #expect(reply.ownerCheck == ConfirmOwnerActionReply(outcome: .declined))
        #expect(isAllow(await evaluate("git push --force origin main", rig)) == false)
    }

    @Test func thePinnedCLIRoleIsPromptedToo() async throws {
        let prompt = FakeAuthenticator(approve: false)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git reset --hard", store: rig.store)
        guard case .attestTTYRedemption(let reply) = await attest(
            params, rig, context: OwnerPresenceTests.cliContext())
        else {
            Issue.record("the pinned CLI must get an owner-check answer")
            return
        }
        #expect(reply.ownerCheck?.outcome == .declined)
        #expect(prompt.promptCount == 1)
    }

    @Test func aCodeRvdDidNotIssueNeverRaisesAPrompt() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let shell = ShellCommand(rawValue: "git reset --hard")
        let forged = AttestTTYRedemptionParams(
            fingerprint: grantFingerprint(Normalize.matchingView(of: shell), invocationPrefix: []),
            cwd: wd("/tmp/ws"), codeHash: CodeHash(rawValue: sha256Hex("abcdef")),
            clientSemver: ProtocolVersion.serviceSemver)
        #expect(await attest(forged, rig) == .error(.allowOnceNotFound))
        #expect(prompt.promptCount == 0)
        #expect(isAllow(await evaluate("git reset --hard", rig)) == false)
    }

    @Test func aSubstitutedCommandCwdOrPayloadNeverRaisesAPrompt() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let issued = try await issue("git push --force origin feature", store: rig.store)
        var otherCommand = issued
        otherCommand.fingerprint = grantFingerprint(MatchingView("git push --force origin main"), invocationPrefix: [])
        var otherCwd = issued
        otherCwd.cwd = wd("/tmp/other")
        var noPayload = issued
        noPayload.payloadDigest = nil
        for params in [otherCommand, otherCwd, noPayload] {
            #expect(await attest(params, rig) == .error(.allowOnceNotFound))
        }
        #expect(prompt.promptCount == 0)
    }

    @Test func thePromptShowsTheExactCommandNotTheMatchingView() async throws {
        // The view drops env values and wrapper flags and blanks
        // interpreter code; the grant still covers them, so the owner
        // sees the text the hook denied.
        let prompt = FakeAuthenticator(approve: false)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let commands = [
            "LD_PRELOAD=/tmp/x.so sudo -u root git push --force origin main",
            "python3 -c 'import shutil; shutil.rmtree(\"/Users\")'",
        ]
        var expected: [String] = []
        for command in commands {
            let params = try await issue(command, store: rig.store)
            expected.append("allow once \"\(command)\" in /tmp/ws (code \(try await issuedCode(of: params, rig)))")
            let result = await attest(params, rig)
            #expect(result != .error(.allowOnceNotFound), "\(command): \(result) \(params)")
        }
        #expect(prompt.reasons.withLock { $0 } == expected)
    }

    @Test func aCodeIssuedWithoutTheExactTextIsNotShown() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let view = Normalize.matchingView(of: ShellCommand(rawValue: "git reset --hard"))
        let code = try #require(await rig.store.mintFromDeny(
            matchingView: view, cwd: wd("/tmp/ws"), ruleID: nil, now: now)?.code)
        let params = AttestTTYRedemptionParams(
            fingerprint: grantFingerprint(view, invocationPrefix: []), cwd: wd("/tmp/ws"),
            codeHash: CodeHash(rawValue: sha256Hex(code.rawValue)),
            clientSemver: ProtocolVersion.serviceSemver)
        guard case .attestTTYRedemption(let reply) = await attest(params, rig) else {
            Issue.record("an unshowable code must answer with the owner check")
            return
        }
        #expect(reply.notShowable == true)
        #expect(reply.planted == false)
        #expect(prompt.promptCount == 0)
    }

    @Test func aPreArmedOrForgedFileRowNeverRaisesAPromptEvenForThePinnedCLI() async throws {
        // `rv allow-once mint` runs in the CLI, so rvd never saw the
        // command, and anyone same-user can write the pending file. rvd
        // prompts only for codes it issued, whatever the caller's role.
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await rig.store.mint(
            matchingView: "rm -rf ~", cwd: wd("/tmp/ws"), ruleID: nil, tty: tty, now: now)
        let row = try #require(await rig.store.validatePending(code: code.rawValue, now: now))
        let preArmed = AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: row.fingerprint), cwd: wd("/tmp/ws"),
            codeHash: CodeHash(rawValue: sha256Hex(code.rawValue)),
            clientSemver: ProtocolVersion.serviceSemver)
        // A row rewritten to another command under a code rvd did issue.
        var forged = try await issue("git status", store: rig.store)
        forged.fingerprint = GrantFingerprint(rawValue: row.fingerprint)
        for context in [OwnerPresenceTests.cliContext(), OwnerPresenceTests.unroledXPCContext()] {
            #expect(await attest(preArmed, rig, context: context) == .error(.allowOnceNotFound))
            #expect(await attest(forged, rig, context: context) == .error(.allowOnceNotFound))
        }
        #expect(prompt.promptCount == 0)
        #expect(isAllow(await evaluate("rm -rf ~", rig)) == false)
    }

    @Test func aRetryAfterThePlantDoesNotPromptAgain() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git reset --hard", store: rig.store)
        guard case .attestTTYRedemption(let first) = await attest(params, rig), first.planted else {
            Issue.record("first attest must plant")
            return
        }
        guard case .attestTTYRedemption(let second) = await attest(params, rig) else {
            Issue.record("a retry must answer")
            return
        }
        #expect(second.planted == false)
        #expect(second.ownerCheck == nil)
        #expect(prompt.promptCount == 1)
    }

    @Test func noPromptAvailableIsUnavailableAndPlantsNothing() async throws {
        // Headless (ssh, no login session): no one can answer, so nothing plants.
        let prompt = FakeAuthenticator(approve: true, available: false)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git reset --hard", store: rig.store)
        guard case .attestTTYRedemption(let reply) = await attest(params, rig) else {
            Issue.record("unavailable must answer with the owner check")
            return
        }
        #expect(reply.ownerCheck?.outcome == .unavailable)
        #expect(prompt.promptCount == 0)
        #expect(isAllow(await evaluate("git reset --hard", rig)) == false)
    }

    @Test func declinedOwnerActionsLockRedeemsOutToo() async throws {
        let prompt = FakeAuthenticator(approve: false)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        for _ in 0..<OwnerPresence.maxFailures {
            _ = await rig.runtime.dispatch(
                IPCRequest(method: .confirmOwnerAction(ConfirmOwnerActionParams(
                    summary: "set safety to normal", proof: nil, clientSemver: "1.0.0"))),
                context: OwnerPresenceTests.unroledXPCContext())
        }
        let params = try await issue("git reset --hard", store: rig.store)
        guard case .attestTTYRedemption(let reply) = await attest(params, rig) else {
            Issue.record("a locked redeem must answer with the owner check")
            return
        }
        #expect(reply.ownerCheck?.outcome == .lockedOut)
        #expect(prompt.promptCount == OwnerPresence.maxFailures)
    }

    @Test func unauthenticatedCallersAreRefusedBeforeAnyPrompt() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git reset --hard", store: rig.store)
        #expect(await attest(params, rig, context: .unauthenticated) == .error(.authorizationDenied))
        #expect(await attest(params, rig, context: peerOperatorUIContext()) == .error(.authorizationDenied))
        #expect(prompt.promptCount == 0)
    }

    @Test func theAuditLineNamesTheRedeemButNotTheCommand() async throws {
        let rig = try rig(FakeAuthenticator(approve: true))
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git push --force origin main", store: rig.store)
        _ = await attest(params, rig)
        let url = AuditLog.fileURL(configDirectory: RVPolicyPaths.configDirectory(home: rig.home))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("redeem allow-once code"))
        #expect(text.contains("origin main") == false)
    }

    @Test func theMatrixAdmitsAuthenticatedRoleLessPeersButNoOtherComponent() {
        // The handler is the gate: it answers only for codes rvd issued and
        // plants only after the owner check.
        let method = IPCMethod.attestTTYRedemption(AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: String(repeating: "a", count: 64)),
            cwd: wd("/tmp/ws"), codeHash: CodeHash(rawValue: String(repeating: "b", count: 64)),
            clientSemver: ProtocolVersion.serviceSemver))
        #expect(ServiceMethodAuthorization.permits(method, context: OwnerPresenceTests.unroledXPCContext()))
        #expect(ServiceMethodAuthorization.permits(method, context: OwnerPresenceTests.socketContext()))
        #expect(ServiceMethodAuthorization.permits(method, context: OwnerPresenceTests.cliContext()))
        #expect(ServiceMethodAuthorization.permits(method, context: peerOperatorUIContext()) == false)
        #expect(ServiceMethodAuthorization.permits(method, context: .unauthenticated) == false)
    }

    // MARK: one prompt at a time, closed on timeout, only while issued

    private func waitForPrompt(_ prompt: FakeAuthenticator) async throws {
        for _ in 0..<1_000 where prompt.promptCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(prompt.promptCount == 1)
    }

    @Test func aSecondRedeemWhileAPromptIsOpenIsBusyAndRaisesNoPrompt() async throws {
        let prompt = FakeAuthenticator(approve: false, hangs: true)
        let rig = try rig(prompt, promptTimeout: .seconds(3))
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let first = try await issue("git reset --hard", store: rig.store)
        let second = try await issue("git push --force origin main", store: rig.store)
        let open = Task { await attest(first, rig) }
        try await waitForPrompt(prompt)
        guard case .attestTTYRedemption(let busy) = await attest(second, rig) else {
            Issue.record("a redeem during an open prompt must answer with the owner check")
            return
        }
        #expect(busy.ownerCheck?.outcome == .busy)
        #expect(busy.planted == false)
        #expect(prompt.promptCount == 1)
        _ = await open.value
        #expect(isAllow(await evaluate("git push --force origin main", rig)) == false)
    }

    @Test func aPromptNobodyAnswersClosesAsDeclinedAndPlantsNothing() async throws {
        let prompt = FakeAuthenticator(approve: true, hangs: true)
        let rig = try rig(prompt, promptTimeout: .milliseconds(200))
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git reset --hard", store: rig.store)
        guard case .attestTTYRedemption(let reply) = await attest(params, rig) else {
            Issue.record("a timed-out prompt must answer with the owner check")
            return
        }
        #expect(reply.ownerCheck?.outcome == .declined)
        #expect(reply.planted == false)
        #expect(isAllow(await evaluate("git reset --hard", rig)) == false)
    }

    @Test func anExpiredIssuedCodeIsNotFoundAndRaisesNoPrompt() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let clock = TestClock(now)
        let rig = try rig(prompt, clock: clock)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git reset --hard", store: rig.store)
        clock.advance(by: 15 * 60 + 1)
        #expect(await attest(params, rig) == .error(.allowOnceNotFound))
        #expect(prompt.promptCount == 0)
    }

    @Test func anIssuedCodeWhoseRowIsGoneIsPrunedAndNotFound() async throws {
        // The pending row was flipped (spent elsewhere); the next rvd write
        // prunes the issued record, and the code raises no prompt.
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git reset --hard", store: rig.store)
        let code = try await issuedCode(of: params, rig)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        _ = try await rig.store.redeem(code: code, tty: tty, now: now)
        _ = try await issue("git push --force origin main", store: rig.store)
        #expect(await rig.store.issued(codeHash: params.codeHash.rawValue, now: now) == nil)
        #expect(await attest(params, rig) == .error(.allowOnceNotFound))
        #expect(prompt.promptCount == 0)
    }

    // MARK: Linux: the login password, checked by rvd

    private func linuxAttest(
        _ params: AttestTTYRedemptionParams, _ rig: Rig, password: String?,
        context: AuthenticatedRequestContext = OwnerPresenceTests.socketContext()
    ) async -> IPCResult {
        var params = params
        params.ownerProof = password.map { OwnerProof(password: $0) }
        return await rig.runtime.dispatch(
            IPCRequest(method: .attestTTYRedemption(params)), context: context, sameUIDSocket: true
        ).result
    }

    @Test func linuxAskingWithoutAPasswordGetsRvdsDescriptionAndPlantsNothing() async throws {
        // The CLI shows rvd's text above the password prompt, not the
        // same-user pending file's.
        let rig = try rig(nil)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let command = "LD_PRELOAD=/tmp/x.so git push --force origin main"
        let params = try await issue(command, store: rig.store, rule: pushRule)
        guard case .attestTTYRedemption(let reply) = await linuxAttest(params, rig, password: nil) else {
            Issue.record("a redeem without a password must answer with rvd's description")
            return
        }
        #expect(reply.planted == false)
        #expect(reply.ownerCheck?.outcome == .proofRequired)
        let code = try await issuedCode(of: params, rig)
        #expect(reply.promptText == "allow once \"\(command)\" in /tmp/ws (rule core.git:push-force, code \(code))")
        #expect(isAllow(await evaluate(command, rig)) == false)
    }

    @Test func linuxPlantsOnlyWithTheOwnersPassword() async throws {
        let rig = try rig(nil)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let params = try await issue("git reset --hard", store: rig.store)
        guard case .attestTTYRedemption(let refused) = await linuxAttest(params, rig, password: "nope") else {
            Issue.record("a wrong password must answer with the owner check")
            return
        }
        #expect(refused.planted == false)
        #expect(refused.ownerCheck == ConfirmOwnerActionReply(outcome: .wrongPassword))
        guard case .attestTTYRedemption(let reply) = await linuxAttest(params, rig, password: "secret") else {
            Issue.record("the owner's password must plant")
            return
        }
        #expect(reply.planted)
        #expect(isAllow(await evaluate("git reset --hard", rig)))
    }

    @Test func linuxForgedRowIsNotFoundEvenWithThePasswordOrThePinnedCLI() async throws {
        // A row rvd did not issue, written to the same-user pending file:
        // neither the right password nor the pinned CLI role plants it.
        let rig = try rig(nil)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await rig.store.mint(
            matchingView: "rm -rf ~", cwd: wd("/tmp/ws"), ruleID: nil, tty: tty, now: now)
        let row = try #require(await rig.store.validatePending(code: code.rawValue, now: now))
        let forged = AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: row.fingerprint), cwd: wd("/tmp/ws"),
            codeHash: CodeHash(rawValue: sha256Hex(code.rawValue)),
            clientSemver: ProtocolVersion.serviceSemver)
        #expect(await linuxAttest(forged, rig, password: "secret") == .error(.allowOnceNotFound))
        #expect(await linuxAttest(forged, rig, password: nil, context: OwnerPresenceTests.cliContext())
            == .error(.allowOnceNotFound))
        #expect(isAllow(await evaluate("rm -rf ~", rig)) == false)
    }
}

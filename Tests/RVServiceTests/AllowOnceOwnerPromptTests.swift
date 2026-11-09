import Foundation
import Testing
import RVDomain
import RVEngine
import RVHistory
import RVIPC
@testable import RVIsolation
import RVPolicy
@testable import RVService

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

    private struct Rig {
        let runtime: ServiceRuntime
        let store: AllowOnceStore
        let home: HomeDirectory
        let homeURL: URL
    }

    private func rig(_ prompt: FakeAuthenticator) throws -> Rig {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let now = self.now
        let runtime = ServiceRuntime(
            snapshots: nil, catalog: nil, home: home, allowOnce: store, allowOnceDirectory: nil,
            idleExitSeconds: IdleWatchdog.defaultSeconds, log: nil, analytics: nil, clock: { now },
            pendingApprovals: .automatic, ceremonies: WorkspaceOperatorCeremonyService(),
            ownerPresence: OwnerPresence(checker: FakeChecker(accepted: "secret"), authenticator: prompt))
        return Rig(runtime: runtime, store: store, home: home, homeURL: homeURL)
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
            invocationDisplay: Normalize.invocationDisplay(of: shell)
        )?.code)
        return AttestTTYRedemptionParams(
            fingerprint: grantFingerprint(view, invocationPrefix: prefix),
            cwd: wd("/tmp/ws"),
            codeHash: CodeHash(rawValue: sha256Hex(code.rawValue)),
            clientSemver: ProtocolVersion.serviceSemver,
            payloadDigest: maskedPayloadContentDigest(masked))
    }

    private func attest(
        _ params: AttestTTYRedemptionParams, _ rig: Rig,
        context: AuthenticatedRequestContext = OwnerPresenceTests.unroledXPCContext()
    ) async -> IPCResult {
        await rig.runtime.dispatch(IPCRequest(method: .attestTTYRedemption(params)), context: context).result
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
        guard case .attestTTYRedemption(let reply) = await attest(params, rig) else {
            Issue.record("the owner's approval must plant")
            return
        }
        #expect(reply.planted)
        #expect(reply.ownerCheck == nil)
        #expect(prompt.reasons.withLock { $0 }
            == ["allow once \"git push --force origin main\" in /tmp/ws (rule core.git:push-force)"])
        #expect(isAllow(await evaluate("git push --force origin main", rig)))
        #expect(isAllow(await evaluate("git push --force origin main", rig)) == false)
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

    @Test func aPreArmedRowRedeemsOnlyThroughThePinnedCLI() async throws {
        // `rv allow-once mint` runs in the CLI, so rvd never saw the
        // command: the file row is all there is, and anyone same-user can
        // write that file. Only the pinned CLI keeps that path.
        let prompt = FakeAuthenticator(approve: true)
        let rig = try rig(prompt)
        defer { try? FileManager.default.removeItem(at: rig.homeURL) }
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await rig.store.mint(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"), ruleID: nil, tty: tty, now: now)
        let row = try #require(await rig.store.validatePending(code: code.rawValue, now: now))
        let params = AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: row.fingerprint), cwd: wd("/tmp/ws"),
            codeHash: CodeHash(rawValue: sha256Hex(code.rawValue)),
            clientSemver: ProtocolVersion.serviceSemver)
        #expect(await attest(params, rig) == .error(.allowOnceNotFound))
        #expect(prompt.promptCount == 0)
        guard case .attestTTYRedemption(let reply) = await attest(
            params, rig, context: OwnerPresenceTests.cliContext())
        else {
            Issue.record("the pinned CLI must still redeem a pre-armed row")
            return
        }
        #expect(reply.planted)
        #expect(prompt.reasons.withLock { $0 } == ["allow once \"git …\" in /tmp/ws"])
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

    @Test func theMatrixAdmitsAnUnroledXPCPeerButNotABareSocketPeer() {
        let method = IPCMethod.attestTTYRedemption(AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: String(repeating: "a", count: 64)),
            cwd: wd("/tmp/ws"), codeHash: CodeHash(rawValue: String(repeating: "b", count: 64)),
            clientSemver: ProtocolVersion.serviceSemver))
        #expect(ServiceMethodAuthorization.permits(method, context: OwnerPresenceTests.unroledXPCContext()))
        #expect(ServiceMethodAuthorization.permits(method, context: OwnerPresenceTests.socketContext()) == false)
        #expect(ServiceMethodAuthorization.permits(method, context: peerOperatorUIContext()) == false)
    }
}

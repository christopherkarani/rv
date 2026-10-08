import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

/// Step 8B P7 adversarial suite: the §45 attack matrix against the new
/// ergonomics surfaces. Each test names the attack, the expected closed
/// behavior, and observes it end to end.
@Suite("Step 8B adversarial")
struct Step8BAdversarialTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fake native-Ask capability

    @Test func fakeNativeAskCapabilityChangesNothing() {
        // Every host row routes to RVOperatorUI; no row is authoritative
        // and none can block. A spoofed host label selects a different
        // row with identical fail-closed properties.
        for host in HookHost.allCases {
            let cap = HostApprovalCapability.capability(for: host)
            #expect(cap.route == .rvOperatorUI, Comment(rawValue: "\(host)"))
            #expect(cap.nativeAskAuthoritative == false, Comment(rawValue: "\(host)"))
            #expect(cap.canBlockForHuman == false, Comment(rawValue: "\(host)"))
        }
    }

    // MARK: - HookHost spoof

    @Test func hookHostSpoofKeepsVerdict() async throws {
        // The same risky action through two different host labels gets the
        // same verdict (deny) and a pending row each: the host selects
        // codec bytes only, never authority. Each codec gets its own
        // well-formed envelope (a foreign envelope correctly allows as
        // "not our event" instead).
        let approvals = FakePendingApprovals()
        let runtime = try makeAdversarialRuntime(approvals: approvals)
        let cases: [(HookHost, String)] = [
            (.pi, #"{"toolName":"bash","cwd":"/tmp/ws","sessionId":"sess-x","input":{"command":"git reset --hard"}}"#),
            (
                .claude,
                #"{"hook_event_name":"PreToolUse","session_id":"sess-x","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}"#
            ),
        ]
        for (host, stdin) in cases {
            let asked = await runtime.dispatch(
                IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: host, stdin: stdin))),
                context: peerHookContext()
            )
            guard case .hookEvaluate(let reply) = asked.result else {
                Issue.record("consult must dispatch for \(host)")
                return
            }
            // Allow is empty stdout; any deny carries guidance. Exit codes
            // differ per host (JSON-gated hosts deny at 0), so the pending
            // row below is the verdict-parity proof: only ASK creates one.
            #expect(reply.stdout.isEmpty == false, Comment(rawValue: "\(host)"))
        }
        #expect(await approvals.createCalls.count == 2)
        let listed = try await approvals.list(now: now)
        #expect(listed.count == 2)
    }

    // MARK: - Same-user self approval

    @Test func sameUserCannotResolveThroughGenericIPC() async throws {
        // Row-ID knowledge plus any IPC-authenticatable context is not
        // authority: generic pendingResolve stays denied from every
        // context, including a service-role peer.
        let approvals = FakePendingApprovals()
        let homeURL = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            clock: { self.now },
            pendingApprovals: .coordinator(approvals)
        )
        let wait = try await approvals.create(
            PendingApprovalRequest(
                id: ApprovalID(rawValue: "self-1"),
                identity: ApprovalIdentity(
                    session: SessionID(validating: "sess-pi")!,
                    agent: .pi
                ),
                action: .shell(
                    ShellAction.effectOnly(EffectShell(
                        fingerprint: ActionFingerprint(rawValue: "shell:self-1"),
                        scope: ActionScope(workingDirectory: wd("/tmp/ws")),
                        supportingCommand: ShellCommand(rawValue: "git reset --hard")
                    ))
                ),
                reason: .hostAsk,
                continuation: .hostNative,
                timeoutPolicy: .keepWaiting
            ),
            now: now
        )
        for context in [AuthenticatedRequestContext.unauthenticated, peerHookContext(), peerServiceContext()] {
            let denied = await runtime.dispatch(
                IPCRequest(method: .pendingResolve(PendingResolveParams(
                    id: wait.id,
                    decision: .allowOnce,
                    fingerprint: wait.fingerprint,
                    identity: wait.identity
                ))),
                context: context
            )
            #expect(denied.result == .error(.authorizationDenied))
        }
        #expect(await approvals.resolveCalls.isEmpty)
    }

    // MARK: - Action substitution

    @Test func approvalForADoesNotAuthorizeB() async throws {
        // Approve `git push origin feature`; the planted grant releases
        // exactly that command once. `git push --force origin main` —
        // different canonical action — still denies, before and after.
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let pending = PendingApprovalStore.makeLive(home: home)
        let grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
        // One shared memory table: the ceremony plants, the world spends.
        let memory = EphemeralAllowOnceTable()
        let ceremonies = HookReviewCeremonyService(
            pending: pending, allowOnce: grants, grants: memory, home: home,
            clock: { self.now })
        let cwd = wd("/tmp/ws")
        let feature = ShellCommand(rawValue: "git push origin feature")
        let created = try await pending.create(
            PendingApprovalRequest(
                id: ApprovalID(rawValue: "sub-1"),
                identity: ApprovalIdentity(
                    session: SessionID(validating: "sess-pi")!,
                    agent: .pi
                ),
                action: .shell(
                    ShellAction.effectOnly(EffectShell(
                        fingerprint: ActionFingerprint.make(
                            host: .pi,
                            session: SessionID(validating: "sess-pi"),
                            cwd: cwd,
                            command: feature
                        ),
                        scope: ActionScope(workingDirectory: cwd),
                        supportingCommand: feature
                    ))
                ),
                reason: .hostAsk,
                continuation: .hostNative,
                timeoutPolicy: .keepWaiting
            ),
            now: now
        )
        _ = created
        let world = {
            await LiveEvaluateWorld(home: home, store: grants, grants: memory, clock: { self.now })
        }
        let forced = ShellCommand(rawValue: "git push --force origin main")
        guard case .deny = await world().apply(command: forced, cwd: cwd).decision else {
            Issue.record("force-push must deny before approval")
            return
        }
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindHookReview(
            approvalID: "sub-1", uiConnection: ui)
        let status = try await ceremonies.completeHookCeremony(
            UIHookCompletion(
                challengeID: challenge.challengeID,
                approvalID: "sub-1",
                outcome: .authenticated
            ),
            uiConnection: ui
        )
        #expect(status == .allowedOnce)
        // The substituted action still denies: the grant binds the exact
        // approved command.
        guard case .deny = await world().apply(command: forced, cwd: cwd).decision else {
            Issue.record("force-push must deny after approving plain push")
            return
        }
        // The approved action releases exactly once.
        guard case .allow = await world().apply(command: feature, cwd: cwd).decision else {
            Issue.record("approved push must allow once")
            return
        }
        guard case .deny = await world().apply(command: feature, cwd: cwd).decision else {
            Issue.record("approved push must deny on replay")
            return
        }
        // And the substitution still denies after the grant is spent.
        guard case .deny = await world().apply(command: forced, cwd: cwd).decision else {
            Issue.record("force-push must deny after grant spent")
            return
        }
    }

    // MARK: - No-Ask host

    @Test func noAskHostFailsClosedWithGuidance() async throws {
        // No host offers native Ask; the consult denies with retry
        // guidance plus a pending row and a TTY code path — never ALLOW.
        let approvals = FakePendingApprovals()
        let runtime = try makeAdversarialRuntime(approvals: approvals)
        let stdin =
            #"{"hookEventName":"pre_tool_use","sessionId":"sess-g","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git push origin feature"}}"#
        let asked = await runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .grok, stdin: stdin))),
            context: peerHookContext()
        )
        guard case .hookEvaluate(let reply) = asked.result else {
            Issue.record("consult must dispatch")
            return
        }
        #expect(reply.stdout.contains(#""decision":"deny""#))
        #expect(await approvals.createCalls.count == 1)
    }

    // MARK: - Dead principal (expired row)

    @Test func expiredRowCannotBindOrComplete() async throws {
        // A wait past its TTL is dead: bind reports unknown and no
        // completion can revive it.
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let pending = PendingApprovalStore.makeLive(home: home)
        let grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
        let wall = WallBox(now)
        let ceremonies = HookReviewCeremonyService(
            pending: pending, allowOnce: grants, grants: EphemeralAllowOnceTable(), home: home,
            clock: { wall.now })
        let cwd = wd("/tmp/ws")
        let shell = ShellCommand(rawValue: "git reset --hard")
        _ = try await pending.create(
            PendingApprovalRequest(
                id: ApprovalID(rawValue: "dead-1"),
                identity: ApprovalIdentity(
                    session: SessionID(validating: "sess-pi")!,
                    agent: .pi
                ),
                action: .shell(
                    ShellAction.effectOnly(EffectShell(
                        fingerprint: ActionFingerprint.make(
                            host: .pi,
                            session: SessionID(validating: "sess-pi"),
                            cwd: cwd,
                            command: shell
                        ),
                        scope: ActionScope(workingDirectory: cwd),
                        supportingCommand: shell
                    ))
                ),
                reason: .hostAsk,
                continuation: .hostNative,
                timeoutPolicy: .autoDeny,
                ttl: 60
            ),
            now: now
        )
        wall.now = now.addingTimeInterval(3600)
        let ui = AuthenticatedOperatorUIConnectionID()
        await #expect(throws: HookReviewCeremonyError.notReviewable) {
            try await ceremonies.bindHookReview(approvalID: "dead-1", uiConnection: ui)
        }
        #expect(await ceremonies.hookStatus(approvalID: "dead-1") == .timedOut)
        // The ledger refuses to resolve a timed-out row even if addressed
        // directly: the timeout sweep runs inside the mutation.
        await #expect(throws: PendingApprovalError.self) {
            try await pending.resolve(
                id: ApprovalID(rawValue: "dead-1"),
                decision: .allowOnce,
                fingerprint: ActionFingerprint.make(
                    host: .pi,
                    session: SessionID(validating: "sess-pi"),
                    cwd: cwd,
                    command: shell
                ),
                identity: ApprovalIdentity(
                    session: SessionID(validating: "sess-pi")!,
                    agent: .pi
                ),
                now: wall.now
            )
        }
    }
}

private final class WallBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private func makeAdversarialRuntime(
    approvals: FakePendingApprovals
) throws -> ServiceRuntime {
    let homeURL = try isolatedHomeDirectory()
    let home = try #require(HomeDirectory(validating: homeURL.path))
    return ServiceRuntime(
        home: home,
        allowOnceDirectory: try isolatedAllowOnceDirectory(),
        clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        pendingApprovals: .coordinator(approvals)
    )
}

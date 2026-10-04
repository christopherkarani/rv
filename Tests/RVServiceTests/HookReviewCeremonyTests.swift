import Foundation
import Synchronization
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

@Suite("HookReviewCeremony")
struct HookReviewCeremonyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func listShowsAwaitingRowsWithTrustedDisplay() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        let created = try await env.seed(command: "git reset --hard", id: "hook-1")

        let list = await env.ceremonies.listHookReviews()
        let item = try #require(list.items.first(where: { $0.approvalID == "hook-1" }))
        #expect(item.host == "pi")
        #expect(item.session == "sess-pi")
        #expect(item.actionKind == "shell")
        #expect(item.exactCommand == "git reset --hard")
        #expect(item.workingDirectory == "/tmp/ws")
        #expect(item.policyReason == "hostAsk")
        #expect(item.actionFingerprint == created.fingerprint.rawValue)
        #expect(item.status == "awaitingHuman")
        #expect(item.advisoryExpiresWall == created.expiresAt)
    }

    @Test func listRedactsSecretShapedCommandText() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "deploy --token ghp_secret hunter2", id: "hook-secret")

        let list = await env.ceremonies.listHookReviews()
        let item = try #require(list.items.first(where: { $0.approvalID == "hook-secret" }))
        #expect(item.exactCommand.contains("ghp_secret") == false)
        #expect(item.actionFingerprint.contains("ghp_secret") == false)
    }

    @Test func bindIssuesChallengeAndResumesForOwner() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        let created = try await env.seed(command: "git reset --hard", id: "hook-2")
        let ui = AuthenticatedOperatorUIConnectionID()

        let (challenge, item) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-2", uiConnection: ui)
        #expect(challenge.approvalID == "hook-2")
        #expect(challenge.actionFingerprint == created.fingerprint.rawValue)
        #expect(challenge.uiConnectionID == ui.rawValue)
        #expect(item.status == "awaitingAuthentication")

        let (resumed, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-2", uiConnection: ui)
        #expect(resumed.challengeID == challenge.challengeID)
    }

    @Test func bindFromSecondConnectionIsNotReviewable() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-3")

        _ = try await env.ceremonies.bindHookReview(
            approvalID: "hook-3", uiConnection: AuthenticatedOperatorUIConnectionID())
        await #expect(throws: HookReviewCeremonyError.notReviewable) {
            try await env.ceremonies.bindHookReview(
                approvalID: "hook-3", uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func completeAllowOncePlantsExactlyOneGrant() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-4")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-4", uiConnection: ui)

        let status = try await env.ceremonies.completeHookCeremony(
            UIHookCompletion(
                challengeID: challenge.challengeID,
                approvalID: "hook-4",
                outcome: .authenticated
            ),
            uiConnection: ui
        )
        #expect(status == "allowedOnce")
        #expect(try await env.grantedCount() == 1)
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-4") == "allowedOnce")
    }

    @Test func completeIsSingleUseReplayFailsClosed() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-5")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-5", uiConnection: ui)
        let completion = UIHookCompletion(
            challengeID: challenge.challengeID,
            approvalID: "hook-5",
            outcome: .authenticated
        )
        _ = try await env.ceremonies.completeHookCeremony(completion, uiConnection: ui)

        // The challenge is consumed: replay names an unknown ceremony.
        await #expect(throws: HookReviewCeremonyError.unknownApproval) {
            try await env.ceremonies.completeHookCeremony(completion, uiConnection: ui)
        }
        #expect(try await env.grantedCount() == 1)
    }

    @Test func completeFromOtherConnectionIsNotReviewable() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-6")
        let owner = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-6", uiConnection: owner)

        await #expect(throws: HookReviewCeremonyError.notReviewable) {
            try await env.ceremonies.completeHookCeremony(
                UIHookCompletion(
                    challengeID: challenge.challengeID,
                    approvalID: "hook-6",
                    outcome: .authenticated
                ),
                uiConnection: AuthenticatedOperatorUIConnectionID()
            )
        }
        #expect(try await env.grantedCount() == 0)
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-6") == "awaitingHuman")
    }

    @Test func completeWithoutAuthenticationFailsAndDropsChallenge() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-7")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-7", uiConnection: ui)

        await #expect(throws: HookReviewCeremonyError.authenticationFailed) {
            try await env.ceremonies.completeHookCeremony(
                UIHookCompletion(
                    challengeID: challenge.challengeID,
                    approvalID: "hook-7",
                    outcome: .cancelled
                ),
                uiConnection: ui
            )
        }
        #expect(try await env.grantedCount() == 0)
        // The row stays awaiting; the human can bind again and retry.
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-7") == "awaitingHuman")
        let (fresh, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-7", uiConnection: ui)
        #expect(fresh.challengeID != challenge.challengeID)
    }

    @Test func denyResolvesWithoutGrantAndWithoutAuthentication() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-8")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-8", uiConnection: ui)

        let status = try await env.ceremonies.denyHookCeremony(
            UIHookDeny(challengeID: challenge.challengeID, approvalID: "hook-8"),
            uiConnection: ui
        )
        #expect(status == "denied")
        #expect(try await env.grantedCount() == 0)
    }

    @Test func denyFromOtherConnectionIsNotReviewable() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-9")
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-9", uiConnection: AuthenticatedOperatorUIConnectionID())

        await #expect(throws: HookReviewCeremonyError.notReviewable) {
            try await env.ceremonies.denyHookCeremony(
                UIHookDeny(challengeID: challenge.challengeID, approvalID: "hook-9"),
                uiConnection: AuthenticatedOperatorUIConnectionID()
            )
        }
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-9") == "awaitingHuman")
    }

    @Test func cancelReleasesReviewButLeavesWaitAwaiting() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-10")
        let ui = AuthenticatedOperatorUIConnectionID()
        _ = try await env.ceremonies.bindHookReview(approvalID: "hook-10", uiConnection: ui)

        let status = try await env.ceremonies.cancelHookReview(
            approvalID: "hook-10", uiConnection: ui)
        #expect(status == "awaitingHuman")
        // Re-bind works: cancel never resolved the row.
        let (_, item) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-10", uiConnection: ui)
        #expect(item.status == "awaitingAuthentication")
    }

    @Test func expiredChallengeFailsClosed() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-11")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-11", uiConnection: ui)

        env.advance(by: HookReviewLimits.challengeLifetime + 1)
        await #expect(throws: HookReviewCeremonyError.unknownApproval) {
            try await env.ceremonies.completeHookCeremony(
                UIHookCompletion(
                    challengeID: challenge.challengeID,
                    approvalID: "hook-11",
                    outcome: .authenticated
                ),
                uiConnection: ui
            )
        }
        #expect(try await env.grantedCount() == 0)
    }

    @Test func disconnectDropsBoundChallengesButKeepsRows() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-12")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-12", uiConnection: ui)

        await env.ceremonies.uiConnectionLost(ui)
        await #expect(throws: HookReviewCeremonyError.unknownApproval) {
            try await env.ceremonies.completeHookCeremony(
                UIHookCompletion(
                    challengeID: challenge.challengeID,
                    approvalID: "hook-12",
                    outcome: .authenticated
                ),
                uiConnection: ui
            )
        }
        // The row survives: a live connection can bind it again.
        let (fresh, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-12", uiConnection: AuthenticatedOperatorUIConnectionID())
        #expect(fresh.challengeID != challenge.challengeID)
    }

    @Test func statusProjectsTerminalRows() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-13")
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-13") == "awaitingHuman")
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-missing") == "unknown")

        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-13", uiConnection: ui)
        _ = try await env.ceremonies.denyHookCeremony(
            UIHookDeny(challengeID: challenge.challengeID, approvalID: "hook-13"),
            uiConnection: ui
        )
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-13") == "denied")
    }

    @Test func bindTerminalRowIsNotReviewable() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-14")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-14", uiConnection: ui)
        _ = try await env.ceremonies.denyHookCeremony(
            UIHookDeny(challengeID: challenge.challengeID, approvalID: "hook-14"),
            uiConnection: ui
        )
        await #expect(throws: HookReviewCeremonyError.notReviewable) {
            try await env.ceremonies.bindHookReview(approvalID: "hook-14", uiConnection: ui)
        }
    }
}

private final class FrozenClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class HookCeremonyEnv {
    private let homeURL: URL
    private let allowOnceDirectory: URL
    private let frozen: FrozenClock
    let ceremonies: HookReviewCeremonyService
    let pending: PendingApprovalStore
    let grants: AllowOnceStore

    init(now: Date) throws {
        homeURL = try isolatedHomeDirectory()
        allowOnceDirectory = try isolatedAllowOnceDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let frozen = FrozenClock(now)
        self.frozen = frozen
        pending = PendingApprovalStore.makeLive(home: home)
        grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
        ceremonies = HookReviewCeremonyService(
            pending: pending,
            allowOnce: grants,
            grants: EphemeralAllowOnceTable(),
            home: home,
            clock: { frozen.now }
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: homeURL)
        try? FileManager.default.removeItem(at: allowOnceDirectory)
    }

    func advance(by interval: TimeInterval) {
        frozen.now = frozen.now.addingTimeInterval(interval)
    }

    func seed(command: String, id: String) async throws -> PendingApproval {
        let shell = ShellCommand(rawValue: command)
        let cwd = wd("/tmp/ws")
        return try await pending.create(
            PendingApprovalRequest(
                id: ApprovalID(rawValue: id),
                identity: ApprovalIdentity(
                    session: SessionID(validating: "sess-pi")!,
                    agent: .pi
                ),
                action: .shell(
                    ShellAction(
                        fingerprint: ActionFingerprint.make(
                            host: .pi,
                            session: SessionID(validating: "sess-pi"),
                            cwd: cwd,
                            command: shell
                        ),
                        scope: ActionScope(workingDirectory: cwd),
                        supportingCommand: shell
                    )
                ),
                reason: .hostAsk,
                continuation: .hostNative,
                timeoutPolicy: .keepWaiting
            ),
            now: frozen.now
        )
    }

    func grantedCount() async throws -> Int {
        await grants.list(now: frozen.now).filter { $0.kind == .granted }.count
    }
}

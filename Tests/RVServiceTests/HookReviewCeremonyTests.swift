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
        #expect(item.status == .awaitingHuman)
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
        #expect(item.status == .awaitingAuthentication)

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
        #expect(status == .allowedOnce)
        #expect(try await env.grantedCount() == 1)
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-4") == .allowedOnce)
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

    @Test func completeAfterActionSwapFailsClosedWithoutGrant() async throws {
        // 8B.1 review finding 2: the pending file is same-user writable
        // and the stored fingerprint is attacker-controlled text. Swapping
        // the action under an identical fingerprint between bind and
        // complete must fail the exact-row bind and plant nothing.
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git status", id: "hook-swap")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-swap", uiConnection: ui)
        try env.swapPendingAction(
            approvalID: "hook-swap",
            command: "git push --force origin main",
            cwd: "/tmp/evil"
        )
        await #expect(throws: HookReviewCeremonyError.notReviewable) {
            try await env.ceremonies.completeHookCeremony(
                UIHookCompletion(
                    challengeID: challenge.challengeID,
                    approvalID: "hook-swap",
                    outcome: .authenticated
                ),
                uiConnection: ui
            )
        }
        #expect(try await env.grantedCount() == 0)
    }

    @Test func completeAfterCwdOnlySwapFailsClosedWithoutGrant() async throws {
        // Same bind, cwd-only redirect: the reviewed command matches but
        // the working directory drifted. Must still fail closed.
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git status", id: "hook-swap-cwd")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-swap-cwd", uiConnection: ui)
        try env.swapPendingAction(
            approvalID: "hook-swap-cwd",
            command: "git status",
            cwd: "/tmp/evil"
        )
        await #expect(throws: HookReviewCeremonyError.notReviewable) {
            try await env.ceremonies.completeHookCeremony(
                UIHookCompletion(
                    challengeID: challenge.challengeID,
                    approvalID: "hook-swap-cwd",
                    outcome: .authenticated
                ),
                uiConnection: ui
            )
        }
        #expect(try await env.grantedCount() == 0)
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
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-6") == .awaitingHuman)
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
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-7") == .awaitingHuman)
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
        #expect(status == .denied)
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
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-9") == .awaitingHuman)
    }

    @Test func cancelReleasesReviewButLeavesWaitAwaiting() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-10")
        let ui = AuthenticatedOperatorUIConnectionID()
        _ = try await env.ceremonies.bindHookReview(approvalID: "hook-10", uiConnection: ui)

        let status = try await env.ceremonies.cancelHookReview(
            approvalID: "hook-10", uiConnection: ui)
        #expect(status == .awaitingHuman)
        // Re-bind works: cancel never resolved the row.
        let (_, item) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-10", uiConnection: ui)
        #expect(item.status == .awaitingAuthentication)
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
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-13") == .awaitingHuman)
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-missing") == .unknown)

        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-13", uiConnection: ui)
        _ = try await env.ceremonies.denyHookCeremony(
            UIHookDeny(challengeID: challenge.challengeID, approvalID: "hook-13"),
            uiConnection: ui
        )
        #expect(await env.ceremonies.hookStatus(approvalID: "hook-13") == .denied)
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

    @Test func bindUnknownApprovalIsUnknown() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        await #expect(throws: HookReviewCeremonyError.unknownApproval) {
            try await env.ceremonies.bindHookReview(
                approvalID: "hook-never-seeded",
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func cancelFromOtherConnectionIsNotReviewable() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-15")
        let owner = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-15", uiConnection: owner)

        await #expect(throws: HookReviewCeremonyError.notReviewable) {
            try await env.ceremonies.cancelHookReview(
                approvalID: "hook-15",
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
        // The owner's challenge survives the foreign cancel: re-bind
        // resumes the same live challenge.
        let (resumed, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-15", uiConnection: owner)
        #expect(resumed.challengeID == challenge.challengeID)
    }

    @Test func cancelUnknownApprovalIsUnknown() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        await #expect(throws: HookReviewCeremonyError.unknownApproval) {
            try await env.ceremonies.cancelHookReview(
                approvalID: "hook-never-seeded",
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func completeWithMismatchedChallengeFailsClosedWithoutGrant() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-16")
        _ = try await env.seed(command: "git status", id: "hook-17")
        let ui = AuthenticatedOperatorUIConnectionID()
        let (first, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-16", uiConnection: ui)
        let (second, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-17", uiConnection: ui)

        // Row 16's review presented with row 17's challenge: unknown
        // ceremony, nothing planted, both reviews intact.
        await #expect(throws: HookReviewCeremonyError.unknownApproval) {
            try await env.ceremonies.completeHookCeremony(
                UIHookCompletion(
                    challengeID: second.challengeID,
                    approvalID: "hook-16",
                    outcome: .authenticated
                ),
                uiConnection: ui
            )
        }
        #expect(try await env.grantedCount() == 0)
        let (resumedFirst, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-16", uiConnection: ui)
        #expect(resumedFirst.challengeID == first.challengeID)
        let (resumedSecond, _) = try await env.ceremonies.bindHookReview(
            approvalID: "hook-17", uiConnection: ui)
        #expect(resumedSecond.challengeID == second.challengeID)
    }

    @Test func everyNonAuthenticatedOutcomeDropsChallengeWithoutGrant() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        let ui = AuthenticatedOperatorUIConnectionID()
        var index = 0
        for outcome: UIAuthenticationOutcome in [
            .cancelled, .unavailable, .timedOut, .invalidated, .failed,
        ] {
            let id = "hook-nonauth-\(index)"
            index += 1
            // Distinct commands: identical fingerprints dedupe to one row.
            _ = try await env.seed(command: "echo nonauth-\(id)", id: id)
            let (challenge, _) = try await env.ceremonies.bindHookReview(
                approvalID: id, uiConnection: ui)
            await #expect(throws: HookReviewCeremonyError.authenticationFailed) {
                try await env.ceremonies.completeHookCeremony(
                    UIHookCompletion(
                        challengeID: challenge.challengeID,
                        approvalID: id,
                        outcome: outcome
                    ),
                    uiConnection: ui
                )
            }
            #expect(try await env.grantedCount() == 0, "outcome \(outcome) must plant nothing")
            #expect(
                await env.ceremonies.hookStatus(approvalID: id) == .awaitingHuman,
                "outcome \(outcome) must leave the row awaiting")
            let (fresh, _) = try await env.ceremonies.bindHookReview(
                approvalID: id, uiConnection: ui)
            #expect(
                fresh.challengeID != challenge.challengeID,
                "outcome \(outcome) must drop the challenge for a fresh bind")
        }
    }

    @Test func listMarksAllowOnceAvailabilityByAction() async throws {
        let env = try HookCeremonyEnv(now: now)
        defer { env.tearDown() }
        _ = try await env.seed(command: "git reset --hard", id: "hook-shell")
        _ = try await env.seedFile(id: "hook-file")

        let list = await env.ceremonies.listHookReviews()
        let shell = try #require(list.items.first(where: { $0.approvalID == "hook-shell" }))
        #expect(shell.allowOnceAvailable == true)
        let file = try #require(list.items.first(where: { $0.approvalID == "hook-file" }))
        #expect(file.allowOnceAvailable == false)
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

    func seedFile(id: String) async throws -> PendingApproval {
        let cwd = wd("/tmp/ws")
        let tool = FileToolAction(kind: .read, path: FileToolPath(rawValue: "/tmp/ws/notes.txt"))
        return try await pending.create(
            PendingApprovalRequest(
                id: ApprovalID(rawValue: id),
                identity: ApprovalIdentity(
                    session: SessionID(validating: "sess-pi")!,
                    agent: .pi
                ),
                action: .file(
                    FileAction(
                        fingerprint: ActionFingerprint.make(
                            host: .pi,
                            session: SessionID(validating: "sess-pi"),
                            cwd: cwd,
                            file: tool
                        ),
                        file: tool,
                        scope: ActionScope(workingDirectory: cwd)
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

    struct SwapError: Error {}

    /// Same-user file surgery: rewrites one pending row's action while
    /// preserving its fingerprint string, simulating an attacker racing
    /// the human review.
    func swapPendingAction(approvalID: String, command: String, cwd: String) throws {
        guard let home = HomeDirectory(validating: homeURL.path) else {
            throw SwapError()
        }
        let file = RVPolicyPaths.pendingApprovalsFile(
            inConfigDir: RVPolicyPaths.configDirectory(home: home))
        let text = try String(contentsOf: file, encoding: .utf8)
        var lines: [String] = []
        var swapped = false
        for raw in text.split(separator: "\n") {
            guard var object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
                as? [String: Any]
            else {
                throw SwapError()
            }
            if var approval = object["approval"] as? [String: Any],
                (approval["id"] as? String) == approvalID,
                var action = approval["action"] as? [String: Any],
                var shellCase = action["shell"] as? [String: Any],
                var shell = shellCase["_0"] as? [String: Any],
                var scope = shell["scope"] as? [String: Any]
            {
                shell["supportingCommand"] = command
                scope["workingDirectory"] = cwd
                shell["scope"] = scope
                shellCase["_0"] = shell
                action["shell"] = shellCase
                approval["action"] = action
                object["approval"] = approval
                swapped = true
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let line = String(data: data, encoding: .utf8) else {
                throw SwapError()
            }
            lines.append(line)
        }
        guard swapped else {
            throw SwapError()
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: file, atomically: true, encoding: .utf8)
    }
}

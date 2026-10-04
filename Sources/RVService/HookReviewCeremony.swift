import Foundation
import RVDomain
import RVIPC
import RVPolicy

/// Step 8B hook-review ceremony: operator-UI review for legacy hook asks.
///
/// Mirrors the Step 6 action ceremony's shape (list / bind / complete /
/// deny / cancel / status over a retained challenge bound to one UI
/// connection) but resolves through `HookAskResolver`, never through
/// `AgentInstance` grants: a hook allow-once plants one exact-command
/// allow-once grant and moves one wait to terminal. Secrets/MCP authority
/// can never enter here (F3).
///
/// Hook waits have no agent principal, so there is no principal-liveness
/// check: the authority is the device-owner authentication reported with
/// the completion, validated against the retained challenge (exact row,
/// fingerprint, identity, connection, expiry, single use).
enum HookReviewLimits {
    static let challengeLifetime: TimeInterval = 5 * 60
}

enum HookReviewCeremonyError: Error, Sendable, Equatable {
    case unknownApproval
    case notReviewable
    case expired
    case authenticationFailed
}

actor HookReviewCeremonyService {
    struct Challenge: Sendable, Equatable {
        let id: UUID
        let approvalID: ApprovalID
        let fingerprint: ActionFingerprint
        let identity: ApprovalIdentity
        /// Exact reviewed plant inputs, snapshotted at bind from the row
        /// the human saw. The pending file is same-user writable and the
        /// stored fingerprint string is attacker-controlled text, so the
        /// resolver must compare these — never trust a re-loaded row that
        /// merely repeats the fingerprint.
        let reviewedCommand: ShellCommand?
        let reviewedCwd: WorkingDirectory?
        let uiConnection: AuthenticatedOperatorUIConnectionID
        let issuedWall: Date
        let expiresWall: Date
        var consumed: Bool
    }

    private let pending: (any PendingApprovalCoordinating)?
    private let allowOnce: AllowOnceStore
    private let grants: EphemeralAllowOnceTable
    private let home: HomeDirectory?
    private let clock: @Sendable () -> Date
    private var challenges: [ApprovalID: Challenge] = [:]

    init(
        pending: (any PendingApprovalCoordinating)?,
        allowOnce: AllowOnceStore,
        grants: EphemeralAllowOnceTable,
        home: HomeDirectory?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pending = pending
        self.allowOnce = allowOnce
        self.grants = grants
        self.home = home
        self.clock = clock
    }

    // MARK: - UI review surface

    /// Reviewable hook waits (awaiting-human rows) with their trusted
    /// display projections. Prunes stale challenges first.
    func listHookReviews() async -> UIHookReviewListDTO {
        prune()
        guard let pending else {
            return UIHookReviewListDTO(items: [])
        }
        let rows: [PendingApproval]
        do {
            rows = try await pending.list(now: clock())
        } catch {
            return UIHookReviewListDTO(items: [])
        }
        let items = rows.map { Self.reviewItem(row: $0, bound: challenges[$0.id] != nil) }
        return UIHookReviewListDTO(items: items.sorted { $0.approvalID < $1.approvalID })
    }

    /// Binds one review to one authenticated UI connection: issues the
    /// challenge and returns it with the review item. Re-binding from the
    /// owning connection resumes the live retained challenge instead of
    /// issuing (mirroring the action ceremony): without resumption,
    /// navigating away from a bound review would brick it.
    func bindHookReview(
        approvalID: String,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> (UIHookChallengeDTO, UIHookReviewItemDTO) {
        prune()
        guard let pending else {
            throw HookReviewCeremonyError.unknownApproval
        }
        let id = ApprovalID(rawValue: approvalID)
        let row: PendingApproval
        do {
            row = try await pending.load(id: id, now: clock())
        } catch {
            throw HookReviewCeremonyError.unknownApproval
        }
        guard row.state == .awaitingHuman else {
            throw HookReviewCeremonyError.notReviewable
        }
        if let live = challenges[id], live.uiConnection == uiConnection {
            return (Self.challengeDTO(live), Self.reviewItem(row: row, bound: true))
        }
        if challenges[id] != nil {
            // Another connection holds the live review.
            throw HookReviewCeremonyError.notReviewable
        }
        let now = clock()
        let challenge = Challenge(
            id: UUID(),
            approvalID: id,
            fingerprint: row.fingerprint,
            identity: row.identity,
            reviewedCommand: row.action.supportingCommand,
            reviewedCwd: row.action.scope.workingDirectory,
            uiConnection: uiConnection,
            issuedWall: now,
            expiresWall: min(
                now.addingTimeInterval(HookReviewLimits.challengeLifetime),
                row.expiresAt
            ),
            consumed: false
        )
        challenges[id] = challenge
        return (Self.challengeDTO(challenge), Self.reviewItem(row: row, bound: true))
    }

    /// Applies one UI-reported allow-once outcome to the retained challenge.
    /// The presented IDs must name the retained ceremony; only
    /// `.authenticated` proceeds, and the terminal effect runs through
    /// `HookAskResolver` (resolve-first CAS, exact-command plant).
    func completeHookCeremony(
        _ completion: UIHookCompletion,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> String {
        prune()
        guard let pending else {
            throw HookReviewCeremonyError.unknownApproval
        }
        let id = ApprovalID(rawValue: completion.approvalID)
        guard var challenge = challenges[id],
            challenge.id == completion.challengeID,
            challenge.approvalID == id
        else {
            throw HookReviewCeremonyError.unknownApproval
        }
        guard challenge.uiConnection == uiConnection else {
            throw HookReviewCeremonyError.notReviewable
        }
        guard completion.outcome == .authenticated else {
            challenges.removeValue(forKey: id)
            throw HookReviewCeremonyError.authenticationFailed
        }
        // Single use: the challenge is consumed before the resolver runs so
        // a concurrent completion cannot double-enter.
        challenge.consumed = true
        challenges[id] = challenge
        let result = await HookAskResolver.resolve(
            params: PendingResolveParams(
                id: id,
                decision: .allowOnce,
                fingerprint: challenge.fingerprint,
                identity: challenge.identity
            ),
            reviewedAction: (
                command: challenge.reviewedCommand,
                cwd: challenge.reviewedCwd
            ),
            pending: pending,
            grants: grants,
            projection: allowOnce,
            peek: peek(),
            now: clock()
        )
        challenges.removeValue(forKey: id)
        switch result {
        case .success:
            return await hookStatus(approvalID: completion.approvalID)
        case .failure:
            throw HookReviewCeremonyError.notReviewable
        }
    }

    /// Records an explicit human deny for the exact bound review. No
    /// authentication: deny grants nothing. Still bound to the live
    /// challenge so one connection cannot deny another's review.
    func denyHookCeremony(
        _ deny: UIHookDeny,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> String {
        prune()
        guard let pending else {
            throw HookReviewCeremonyError.unknownApproval
        }
        let id = ApprovalID(rawValue: deny.approvalID)
        guard let challenge = challenges[id],
            challenge.id == deny.challengeID,
            challenge.approvalID == id
        else {
            throw HookReviewCeremonyError.unknownApproval
        }
        guard challenge.uiConnection == uiConnection else {
            throw HookReviewCeremonyError.notReviewable
        }
        let result = await HookAskResolver.resolve(
            params: PendingResolveParams(
                id: id,
                decision: .deny,
                fingerprint: challenge.fingerprint,
                identity: challenge.identity
            ),
            reviewedAction: nil,
            pending: pending,
            grants: grants,
            projection: allowOnce,
            peek: peek(),
            now: clock()
        )
        challenges.removeValue(forKey: id)
        switch result {
        case .success:
            return await hookStatus(approvalID: deny.approvalID)
        case .failure:
            throw HookReviewCeremonyError.notReviewable
        }
    }

    /// Releases the caller's own bound review without deciding it. Only the
    /// connection holding the live challenge may release it. Unlike the
    /// action ceremony, cancel does NOT resolve the row: the wait stays
    /// awaiting until its TTL or a later decision, so navigating away from
    /// a review never denies the agent's action by accident.
    func cancelHookReview(
        approvalID: String,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> String {
        prune()
        let id = ApprovalID(rawValue: approvalID)
        guard let challenge = challenges[id] else {
            throw HookReviewCeremonyError.unknownApproval
        }
        guard challenge.uiConnection == uiConnection else {
            throw HookReviewCeremonyError.notReviewable
        }
        challenges.removeValue(forKey: id)
        return await hookStatus(approvalID: approvalID)
    }

    /// UI-facing status with challenge pruning.
    func hookStatus(approvalID: String) async -> String {
        prune()
        guard let pending else {
            return "unknown"
        }
        let id = ApprovalID(rawValue: approvalID)
        do {
            let row = try await pending.load(id: id, now: clock())
            return Self.statusString(row.state)
        } catch {
            challenges.removeValue(forKey: id)
            return "unknown"
        }
    }

    // MARK: - Disconnect plumbing

    /// Drops every challenge bound to the dead connection. Rows are
    /// untouched: a later bind from a live connection re-opens review.
    func uiConnectionLost(_ uiConnection: AuthenticatedOperatorUIConnectionID) async {
        challenges = challenges.filter { $0.value.uiConnection != uiConnection }
    }

    func uiSessionAuthenticated() async {
        prune()
    }

    // MARK: - Private

    private func peek() -> @Sendable (ShellCommand, WorkingDirectory?, Date) async -> EvaluationResult {
        let home = home
        let store = allowOnce
        let grants = grants
        return { command, cwd, now in
            await LiveEvaluateWorld(home: home, store: store, grants: grants, clock: { now })
                .peek(command: command, cwd: cwd)
        }
    }

    private func prune() {
        let now = clock()
        challenges = challenges.filter { _, challenge in
            challenge.consumed == false && challenge.expiresWall > now
        }
    }

    private static func statusString(_ state: PendingApprovalState) -> String {
        switch state {
        case .awaitingHuman:
            return "awaitingHuman"
        case .resolved(let resolution):
            switch resolution.decision {
            case .allowOnce:
                return "allowedOnce"
            case .createRule:
                return "ruleCreated"
            case .deny:
                return "denied"
            }
        case .consumed:
            return "consumed"
        case .expired:
            return "expired"
        case .canceled:
            return "canceled"
        case .timedOut:
            return "timedOut"
        }
    }

    private static func challengeDTO(_ challenge: Challenge) -> UIHookChallengeDTO {
        UIHookChallengeDTO(
            challengeID: challenge.id,
            approvalID: challenge.approvalID.rawValue,
            actionFingerprint: ReviewSanitizer.redactCredentials(in: challenge.fingerprint.rawValue),
            uiConnectionID: challenge.uiConnection.rawValue,
            issuedWall: challenge.issuedWall,
            advisoryLifetimeSeconds: HookReviewLimits.challengeLifetime
        )
    }

    private static func reviewItem(row: PendingApproval, bound: Bool) -> UIHookReviewItemDTO {
        let (kind, command, cwd) = displayAction(row.action)
        return UIHookReviewItemDTO(
            approvalID: row.id.rawValue,
            host: row.identity.agent.rawValue,
            session: row.identity.session.rawValue,
            actionKind: kind,
            exactCommand: command,
            workingDirectory: cwd,
            policyReason: row.reason.rawValue,
            actionFingerprint: ReviewSanitizer.redactCredentials(in: row.fingerprint.rawValue),
            status: bound ? "awaitingAuthentication" : statusString(row.state),
            advisoryExpiresWall: row.expiresAt
        )
    }

    /// Trusted display for the exact retained action. Secret-shaped text is
    /// redacted for display; the authorization binds the unredacted row.
    private static func displayAction(_ action: ProposedAction) -> (kind: String, command: String, cwd: String) {
        switch action {
        case .shell(let shell):
            let command = shell.supportingCommand.map(\.rawValue) ?? "(no exact command retained)"
            return (
                "shell",
                ReviewSanitizer.redactCredentials(in: command),
                shell.scope.workingDirectory?.rawValue ?? "—"
            )
        case .file(let file):
            let command = "\(file.file.kind.rawValue) \(file.file.path.rawValue)"
            return (
                "file",
                ReviewSanitizer.redactCredentials(in: command),
                file.scope.workingDirectory?.rawValue ?? "—"
            )
        case .http(let http):
            let command = "\(http.method.rawValue) \(http.destination.host)\(http.destination.path)"
            return (
                "http",
                ReviewSanitizer.redactCredentials(in: command),
                http.scope.workingDirectory?.rawValue ?? "—"
            )
        }
    }
}

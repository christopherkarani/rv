import Foundation
import RVDomain
import RVEngine
import RVHistory
import RVIPC
import RVPolicy

/// K2, Approvals with Touch ID: the menu bar's answer to a stop that handed
/// the agent an allow-once code.
///
/// Same shape as the hook-review ceremony (list / bind / complete / release
/// over a challenge rvd retains, bound to one authenticated operator-UI
/// connection), but the thing under review is a code rvd itself issued on a
/// hook deny, and the effects are exactly the terminal's:
/// - allow once plants the one grant `rv allow-once <code>` plants, under
///   the same per-code single-use key, so the terminal and the menu bar can
///   never both spend one code;
/// - always allow writes the one exact-command allowlist entry
///   `rv allowlist add-command` writes (same selector, digests and
///   `config.changed` row), then plants the once grant so the waiting retry
///   goes through.
/// Each writes the owner-action audit row the terminal path writes first,
/// and an approval rvd cannot record changes nothing. The retry then
/// writes the usual `command.override` row when it spends the grant.
///
/// Authority: the device owner's fresh authentication, reported by the
/// pinned operator UI (`operatorUI` role, rvd's own euid) for one bound
/// challenge, and checked here against what rvd issued: exact code,
/// fingerprint, cwd, payload digest, connection, expiry, single use.
/// Nothing the UI sends shapes what is granted: the command, the
/// allowlist entry and the grant all come from rvd's own memory of the code.
enum UnlockReviewLimits {
    static let challengeLifetime: TimeInterval = 5 * 60
    /// How a menu bar approval is recorded on the allowlist change
    /// (`authorized_by`).
    static let authorization = "owner (Touch ID or password in the rv menu bar)"
}

enum UnlockReviewError: Error, Sendable, Equatable {
    /// No live code by this hash, or no live challenge with these ids.
    case unknownCode
    /// Held by another connection, already answered, or changed since bind.
    case notReviewable
    /// The completion did not carry a device-owner authentication.
    case authenticationRequired
    /// rvd could not show the whole command, so nothing may approve it.
    case notShowable
    /// The approval could not be written to the audit log or the allowlist.
    case notRecorded
}

/// The pure rules of an unlock review, kept apart from the actor's state so
/// each is tested on its own.
enum UnlockReviewRules {
    /// Only the pinned operator UI running as rvd's own user may review.
    static func admits(_ context: AuthenticatedRequestContext, ownerUserID: UInt32) -> Bool {
        guard let peer = context.peer, peer.componentRole == .operatorUI else { return false }
        return peer.evidence.effectiveUserID == ownerUserID
    }

    /// The trusted projection of one issued code.
    static func item(codeHash: String, issued: IssuedAllowOnce, bound: Bool) -> UIUnlockItemDTO {
        let command = issued.command ?? ""
        return UIUnlockItemDTO(
            codeHash: codeHash,
            code: issued.code.rawValue,
            checkWords: CheckWords.words(for: issued.code),
            host: issued.stop?.asker,
            command: DisplayedText.approvalField(command),
            workingDirectory: DisplayedText.approvalField(issued.cwd.rawValue),
            rule: issued.ruleID.map { DisplayedText.approvalField($0.rawValue) },
            agentSays: issued.stop?.agentSays.map(DisplayedText.approvalField),
            promptText: promptText(issued),
            status: bound ? .awaitingAuthentication : .waiting,
            advisoryExpiresWall: issued.expiresAt)
    }

    /// rvd's own prompt text for the code: the words the terminal approves.
    static func promptText(_ issued: IssuedAllowOnce) -> String? {
        guard let command = issued.command else { return nil }
        return AllowOncePromptText.reason(
            command: command, cwd: issued.cwd, ruleID: issued.ruleID, code: issued.code.rawValue)
    }

    /// The exact-command allowlist entry `rv allowlist add-command` writes
    /// for this command, built from rvd's own copy of the stopped text.
    static func allowlistEntry(for issued: IssuedAllowOnce, now: Date) -> AllowlistEntry? {
        guard let command = issued.command else { return nil }
        let shell = ShellCommand(rawValue: command)
        let view = EvaluationWorld.matchingView(of: shell)
        guard view.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        return AllowlistEntry(
            selector: .exactCommand(view),
            reason: "always allowed in the rv menu bar (code \(issued.code.rawValue))",
            addedAt: now,
            maskedPayloadDigest: maskedPayloadContentDigest(Normalize.maskedSegments(of: shell)),
            invocationDigest: maskedPayloadContentDigest(Normalize.invocationPrefix(of: shell)))
    }

    /// The owner-action audit summaries the terminal writes for `decision`,
    /// in order: `rv allowlist add-command` first, then the redeem.
    static func auditSummaries(_ decision: UIUnlockDecision) -> [String] {
        switch decision {
        case .allowOnce: ["redeem allow-once code"]
        case .alwaysAllow: ["add allowlist exception for an exact command", "redeem allow-once code"]
        }
    }
}

/// Writes what an approval changes outside rvd's memory: the audit row and
/// the allowlist. Production is `live`; tests record or fail.
struct UnlockReviewRecorder: Sendable {
    var audit: @Sendable (_ summary: String, _ context: AuthenticatedRequestContext) async -> Bool
    var pinAllowlist: @Sendable (_ entry: AllowlistEntry) -> Bool

    static func live(home: HomeDirectory?) -> UnlockReviewRecorder {
        UnlockReviewRecorder(
            audit: { summary, context in
                await OwnerPresence.audit(
                    summary: summary, approved: true, outcome: ConfirmOwnerActionReply.Outcome.approved.rawValue,
                    context: context, home: home)
            },
            pinAllowlist: { entry in
                guard let home else { return false }
                let store = AllowlistStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
                do {
                    try ConfigChangeAudit.$authorization.withValue(UnlockReviewLimits.authorization) {
                        try store.pin(entry)
                    }
                    return true
                } catch {
                    return false
                }
            })
    }
}

actor UnlockReviewCeremonyService {
    struct Challenge: Sendable, Equatable {
        let id: UUID
        let codeHash: String
        /// What rvd issued, snapshotted at bind: a completion must find the
        /// same code still live with these exact bindings.
        let fingerprint: GrantFingerprint
        let cwd: WorkingDirectory
        let payloadDigest: ContentPayloadDigest?
        let uiConnection: AuthenticatedOperatorUIConnectionID
        let issuedWall: Date
        let expiresWall: Date
    }

    private let allowOnce: AllowOnceStore
    private let grants: EphemeralAllowOnceTable
    private let recorder: UnlockReviewRecorder
    private let clock: @Sendable () -> Date
    private var challenges: [String: Challenge] = [:]

    init(
        allowOnce: AllowOnceStore,
        grants: EphemeralAllowOnceTable,
        recorder: UnlockReviewRecorder,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.allowOnce = allowOnce
        self.grants = grants
        self.recorder = recorder
        self.clock = clock
    }

    /// Every live stop rvd can vouch for, oldest first.
    func list() async -> UIUnlockListDTO {
        prune()
        let stops = await allowOnce.liveStops(now: clock())
        let items = stops
            .sorted { lhs, rhs in
                lhs.value.expiresAt != rhs.value.expiresAt
                    ? lhs.value.expiresAt < rhs.value.expiresAt : lhs.key < rhs.key
            }
            .map { UnlockReviewRules.item(codeHash: $0.key, issued: $0.value, bound: challenges[$0.key] != nil) }
        return UIUnlockListDTO(items: items)
    }

    /// Opens one review on one UI connection. Re-binding from the same
    /// connection resumes the live challenge; another connection is refused
    /// while one holds it. Binding never authenticates or grants.
    func bind(
        codeHash: String, uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws(UnlockReviewError) -> UIUnlockChallengeBundleDTO {
        prune()
        let now = clock()
        guard let issued = await allowOnce.liveStops(now: now)[codeHash] else {
            challenges.removeValue(forKey: codeHash)
            throw .unknownCode
        }
        if let live = challenges[codeHash] {
            guard live.uiConnection == uiConnection else { throw .notReviewable }
            return bundle(live, issued: issued)
        }
        let challenge = Challenge(
            id: UUID(), codeHash: codeHash, fingerprint: issued.fingerprint, cwd: issued.cwd,
            payloadDigest: issued.payloadDigest, uiConnection: uiConnection, issuedWall: now,
            expiresWall: min(now.addingTimeInterval(UnlockReviewLimits.challengeLifetime), issued.expiresAt))
        challenges[codeHash] = challenge
        return bundle(challenge, issued: issued)
    }

    /// Applies one answer. The challenge is spent before anything else
    /// runs, whatever the outcome: a replay finds nothing.
    func complete(
        _ completion: UIUnlockCompletion,
        uiConnection: AuthenticatedOperatorUIConnectionID,
        context: AuthenticatedRequestContext
    ) async throws(UnlockReviewError) -> UIUnlockStatus {
        prune()
        guard let challenge = challenges[completion.codeHash], challenge.id == completion.challengeID else {
            throw .unknownCode
        }
        guard challenge.uiConnection == uiConnection else { throw .notReviewable }
        challenges.removeValue(forKey: completion.codeHash)
        guard completion.outcome == .authenticated else { throw .authenticationRequired }
        let now = clock()
        guard let issued = await allowOnce.issued(codeHash: challenge.codeHash, now: now) else {
            throw .unknownCode
        }
        guard issued.origin == .stop, issued.fingerprint == challenge.fingerprint, issued.cwd == challenge.cwd,
            issued.payloadDigest == challenge.payloadDigest
        else { throw .notReviewable }
        if issued.redeemed { return .alreadyAnswered }
        guard UnlockReviewRules.promptText(issued) != nil else { throw .notShowable }
        let entry: AllowlistEntry?
        switch completion.decision {
        case .allowOnce:
            entry = nil
        case .alwaysAllow:
            guard let built = UnlockReviewRules.allowlistEntry(for: issued, now: now) else { throw .notShowable }
            entry = built
        }
        // Audit first, as the terminal does: an approval rvd cannot record
        // changes nothing.
        for summary in UnlockReviewRules.auditSummaries(completion.decision) {
            guard await recorder.audit(summary, context) else { throw .notRecorded }
        }
        if let entry, recorder.pinAllowlist(entry) == false { throw .notRecorded }
        switch await grants.plant(
            fingerprint: issued.fingerprint, cwd: issued.cwd,
            codeHash: CodeHash(rawValue: "tty:\(challenge.codeHash)"), now: now,
            payloadContentDigest: issued.payloadDigest
        ) {
        case .planted:
            await allowOnce.markIssuedRedeemed(codeHash: challenge.codeHash)
            await allowOnce.projectRedeemed(codeHash: challenge.codeHash, now: now)
            return entry == nil ? .allowedOnce : .alwaysAllowed
        case .alreadyRedeemed:
            await allowOnce.markIssuedRedeemed(codeHash: challenge.codeHash)
            return entry == nil ? .alreadyAnswered : .alwaysAllowed
        case .refused:
            throw .notReviewable
        }
    }

    /// Closes the caller's own review without answering it: the command
    /// stays stopped and its code stays live for the terminal.
    func release(
        codeHash: String, uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws(UnlockReviewError) -> UIUnlockStatus {
        prune()
        guard let challenge = challenges[codeHash] else { throw .unknownCode }
        guard challenge.uiConnection == uiConnection else { throw .notReviewable }
        challenges.removeValue(forKey: codeHash)
        return await allowOnce.liveStops(now: clock())[codeHash] == nil ? .unknown : .waiting
    }

    /// A dead connection's reviews die with it; the codes stay live.
    func uiConnectionLost(_ uiConnection: AuthenticatedOperatorUIConnectionID) {
        challenges = challenges.filter { $0.value.uiConnection != uiConnection }
    }

    private func prune() {
        let now = clock()
        challenges = challenges.filter { $0.value.expiresWall > now }
    }

    private func bundle(_ challenge: Challenge, issued: IssuedAllowOnce) -> UIUnlockChallengeBundleDTO {
        UIUnlockChallengeBundleDTO(
            challenge: UIUnlockChallengeDTO(
                challengeID: challenge.id, codeHash: challenge.codeHash,
                uiConnectionID: challenge.uiConnection.rawValue, issuedWall: challenge.issuedWall,
                advisoryLifetimeSeconds: max(0, challenge.expiresWall.timeIntervalSince(challenge.issuedWall))),
            item: UnlockReviewRules.item(codeHash: challenge.codeHash, issued: issued, bound: true))
    }
}

/// The unlock request vocabulary over one admitted operator-UI peer.
/// Platform-neutral so the gate and the dispatch are tested on Linux; the
/// macOS XPC bridge only unwraps the frame and calls it.
enum UnlockReviewBridge {
    static func reply(
        _ request: UIUnlockBridgeRequest,
        context: AuthenticatedRequestContext,
        handshakeOK: Bool,
        discoveryOnly: Bool,
        sessions: LiveOperatorUISessionRegistry,
        ceremony: UnlockReviewCeremonyService,
        ownerUserID: UInt32 = ServiceMethodAuthorization.ownerUserID
    ) async -> IPCResult {
        guard handshakeOK, !discoveryOnly, UnlockReviewRules.admits(context, ownerUserID: ownerUserID),
            let peer = context.peer,
            let session = await sessions.session(connectionID: peer.connectionID)
        else { return .error(.authorizationDenied) }
        do {
            switch request {
            case .unlockList:
                return .uiUnlockList(await ceremony.list())
            case .unlockBind(let codeHash):
                return .uiUnlockChallengeBundle(
                    try await ceremony.bind(codeHash: codeHash, uiConnection: session.uiConnection))
            case .unlockComplete(let completion):
                let status = try await ceremony.complete(
                    completion, uiConnection: session.uiConnection, context: context)
                return .uiUnlockStatus(UIUnlockStatusDTO(codeHash: completion.codeHash, status: status))
            case .unlockRelease(let codeHash):
                let status = try await ceremony.release(codeHash: codeHash, uiConnection: session.uiConnection)
                return .uiUnlockStatus(UIUnlockStatusDTO(codeHash: codeHash, status: status))
            }
        } catch {
            // Opaque: a refusal says nothing about which check failed.
            return .error(.authorizationDenied)
        }
    }
}

import Foundation
import RVDomain

/// What an owner's egress approval was reviewed against. Opaque: callers
/// only compare tokens, never parse them.
///
/// Not a credential. It proves nothing about who approved; owner
/// authentication still does that. It only ties an authenticated decision
/// to the state the owner saw.
public struct EgressReviewToken: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Review binding for network proposals (OpenShell's proposal review
/// token, fit to rv). The token hashes the proposal as shown plus the
/// effective egress policy it was reviewed against. If either moves
/// between showing the proposal and applying the approval, the tokens
/// differ and the approval is refused.
///
/// The effective egress policy of a workspace is the static policy every
/// runtime proxy enforces plus the live grants the owner approved for that
/// workspace. The static policy is compiled in, so it cannot change
/// between a display and an approval in one process. The grant set can:
/// it is the workspace's network-proposal rows whose resolution authorizes
/// the rule. Rows of other workspaces and denials change no grant here.
public enum EgressReview: Sendable {
    static let domainTag = "rv-egress-review/v1"

    /// Rules the owner granted to `identity`'s workspace, sorted and
    /// unique. Resolved and consumed rows both count: the live channel
    /// never drops a loaded rule within a supervisor lifetime.
    public static func grants(
        for identity: ApprovalIdentity,
        in records: [PendingApproval]
    ) -> [LiveNetworkRule] {
        let rules = records.compactMap { record -> LiveNetworkRule? in
            guard record.identity == identity, authorizes(record.state) else { return nil }
            return EgressProposal.rule(for: record)
        }
        return Set(rules).sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    /// Token for the awaiting network proposal `id` against `records`
    /// (the swept ledger). Nil when no such row awaits a human: nothing
    /// there can be approved, so there is nothing to bind.
    public static func token(for id: ApprovalID, in records: [PendingApproval]) -> EgressReviewToken? {
        guard let proposal = records.first(where: { $0.id == id }),
            case .awaitingHuman = proposal.state,
            let rule = EgressProposal.rule(for: proposal)
        else { return nil }
        let grants = grants(for: proposal.identity, in: records)
        var fields = [
            domainTag,
            proposal.id.rawValue,
            proposal.fingerprint.rawValue,
            rule.host,
            String(rule.port),
            proposal.identity.session.rawValue,
            proposal.identity.agent.rawValue,
            proposal.action.scope.workingDirectory?.rawValue ?? "",
            proposal.reason.rawValue,
            String(proposal.createdAt.timeIntervalSince1970.bitPattern),
            String(proposal.expiresAt.timeIntervalSince1970.bitPattern),
            String(grants.count),
        ]
        fields += grants.map { "\($0.host):\($0.port)" }
        return EgressReviewToken(rawValue: RVDigest.sha256Hex(lengthPrefixed(fields)))
    }

    private static func authorizes(_ state: PendingApprovalState) -> Bool {
        switch state {
        case .resolved(let resolution), .consumed(let resolution, _):
            return resolution.decision.authorizesExactAction
        case .awaitingHuman, .expired, .canceled, .timedOut:
            return false
        }
    }

    /// `<utf8 length>:<bytes>` per field, so no field can borrow bytes
    /// from its neighbour (ids and session names are file text).
    private static func lengthPrefixed(_ fields: [String]) -> [UInt8] {
        fields.flatMap { field in Array("\(field.utf8.count):".utf8) + Array(field.utf8) }
    }
}

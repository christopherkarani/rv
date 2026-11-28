import Foundation
import RVDomain

// Loosen proposals (workstream F2): an agent's loosen is stored by rvd as a
// proposal; rvd applies it only after the device owner approves that exact
// proposal at rvd's own owner check, bound by its content hash.
//
// Trust: any kernel-attested local peer may file, list or decline (none of
// those loosens anything). `decideProposal` with `approve` gets its
// authority only from `OwnerPresence` in rvd, as `confirmOwnerAction` does;
// rvd builds the prompt text from the stored row, never from the caller.
// Sizes: a change is bounded by `PolicyLoosen` limits, labels by
// `ProposeLoosenParams.maxLabelBytes`; rvd keeps at most 32 pending.

/// One proposal as rvd shows it. `createdAtMs` and `decidedAtMs` are
/// milliseconds since 1970 (no `Date` crosses `rv.ipc.v1`).
public struct ProposalItem: Sendable, Equatable, Codable {
    public var id: ProposalID
    public var change: PolicyLoosen
    public var from: String?
    public var cwd: String?
    public var createdAtMs: Int64
    /// SHA-256 hex over everything shown (`LoosenProposalLedger.contentHash`).
    /// An approval must send it back unchanged.
    public var contentHash: String
    public var status: ProposalStatus
    public var decidedAtMs: Int64?
    public var declineReason: String?

    public init(
        id: ProposalID, change: PolicyLoosen, from: String?, cwd: String?, createdAtMs: Int64,
        contentHash: String, status: ProposalStatus, decidedAtMs: Int64? = nil, declineReason: String? = nil
    ) {
        self.id = id
        self.change = change
        self.from = from
        self.cwd = cwd
        self.createdAtMs = createdAtMs
        self.contentHash = contentHash
        self.status = status
        self.decidedAtMs = decidedAtMs
        self.declineReason = declineReason
    }
}

/// `proposeLoosen`: file one loosen. Never applies anything.
public struct ProposeLoosenParams: Sendable, Equatable, Codable {
    /// Longest `from` or `cwd`, in UTF-8 bytes; rvd refuses longer ones.
    public static let maxLabelBytes = 1024

    public var change: PolicyLoosen
    public var from: String?
    public var cwd: String?
    public var clientSemver: String

    public init(change: PolicyLoosen, from: String?, cwd: String?, clientSemver: String) {
        self.change = change
        self.from = from
        self.cwd = cwd
        self.clientSemver = clientSemver
    }
}

public struct ProposeLoosenReply: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Equatable, Codable {
        /// Stored (or the same change was already waiting: `created == false`).
        case filed
        /// The change is malformed; `problem` says why.
        case invalid
        /// Too many proposals wait already.
        case full
        /// rvd could not read or write its proposal store.
        case unavailable
    }

    public var outcome: Outcome
    public var proposal: ProposalItem?
    public var created: Bool
    public var problem: String?

    public init(outcome: Outcome, proposal: ProposalItem? = nil, created: Bool = false, problem: String? = nil) {
        self.outcome = outcome
        self.proposal = proposal
        self.created = created
        self.problem = problem
    }
}

/// `listProposals`.
public struct ListProposalsParams: Sendable, Equatable, Codable {
    /// Also return approved, declined and expired rows.
    public var includeDecided: Bool

    public init(includeDecided: Bool = false) {
        self.includeDecided = includeDecided
    }
}

public struct ListProposalsReply: Sendable, Equatable, Codable {
    public var proposals: [ProposalItem]
    /// False when rvd could not read its store (the list is then empty).
    public var readable: Bool

    public init(proposals: [ProposalItem], readable: Bool = true) {
        self.proposals = proposals
        self.readable = readable
    }
}

/// `decideProposal`: approve (owner-checked) or decline one proposal, by
/// the content hash the caller showed the owner.
public struct DecideProposalParams: Sendable, Equatable, Codable {
    public enum Decision: String, Sendable, Equatable, Codable {
        case approve
        case reject
    }

    public var id: ProposalID
    public var contentHash: String
    public var decision: Decision
    /// The owner's words for a decline. At most 280 bytes are kept.
    public var reason: String?
    /// Linux: the owner's login password for rvd to check. macOS: nil
    /// (rvd shows its own prompt).
    public var proof: OwnerProof?
    public var clientSemver: String

    public init(
        id: ProposalID, contentHash: String, decision: Decision, reason: String? = nil, proof: OwnerProof? = nil,
        clientSemver: String
    ) {
        self.id = id
        self.contentHash = contentHash
        self.decision = decision
        self.reason = reason
        self.proof = proof
        self.clientSemver = clientSemver
    }
}

public struct DecideProposalReply: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Equatable, Codable {
        /// The owner approved and rvd applied the change.
        case approved
        /// Declined; nothing changed.
        case rejected
        /// The proposal no longer hashes to `contentHash`; nothing changed.
        case changed
        case notFound
        /// Already approved, declined or expired (`proposal.status`).
        case notPending
        /// The owner check did not pass (`owner` says how).
        case ownerRefused
        /// The stored change is malformed; `problem` says why.
        case invalid
        /// The owner approved but rvd could not apply it (`problem`); the
        /// proposal stays pending and nothing changed.
        case applyFailed
        /// rvd could not read or write its proposal store.
        case unavailable
    }

    public var outcome: Outcome
    public var proposal: ProposalItem?
    /// rvd's owner check answer, for `approved` and `ownerRefused`.
    public var owner: ConfirmOwnerActionReply?
    public var problem: String?

    public init(
        outcome: Outcome, proposal: ProposalItem? = nil, owner: ConfirmOwnerActionReply? = nil, problem: String? = nil
    ) {
        self.outcome = outcome
        self.proposal = proposal
        self.owner = owner
        self.problem = problem
    }
}

/// A proposal was filed or decided (live event kind `proposal`). Carries
/// no command text or reason: readers fetch the row with `listProposals`.
public struct LiveProposal: Sendable, Equatable, Codable {
    public var id: ProposalID
    public var status: ProposalStatus
    /// `PolicyLoosen.kind`.
    public var kind: String
    public var from: String?

    public init(id: ProposalID, status: ProposalStatus, kind: String, from: String?) {
        self.id = id
        self.status = status
        self.kind = kind
        self.from = from
    }
}

public struct ProposeLoosenCall: IPCCall {
    public var params: ProposeLoosenParams
    public var method: IPCMethod { .proposeLoosen(params) }

    public init(params: ProposeLoosenParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> ProposeLoosenReply? {
        if case .proposeLoosen(let reply) = result { return reply }
        return nil
    }
}

public struct ListProposalsCall: IPCCall {
    public var params: ListProposalsParams
    public var method: IPCMethod { .listProposals(params) }

    public init(params: ListProposalsParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> ListProposalsReply? {
        if case .listProposals(let reply) = result { return reply }
        return nil
    }
}

public struct DecideProposalCall: IPCCall {
    public var params: DecideProposalParams
    public var method: IPCMethod { .decideProposal(params) }

    public init(params: DecideProposalParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> DecideProposalReply? {
        if case .decideProposal(let reply) = result { return reply }
        return nil
    }
}

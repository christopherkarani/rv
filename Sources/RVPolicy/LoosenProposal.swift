#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import RVDomain

/// One stored loosen proposal (workstream F2). rvd writes these; nothing
/// else applies them. `contentHash` binds everything the owner is shown,
/// so an approval names exactly one content.
public struct LoosenProposal: Sendable, Equatable, Codable {
    public var id: ProposalID
    public var change: PolicyLoosen
    /// Who asked, as the proposer described itself ("claude"). Untrusted label.
    public var from: String?
    /// The proposer's working directory. Untrusted label.
    public var cwd: String?
    public var createdAt: Date
    /// `LoosenProposalLedger.contentHash` of id, change, from and cwd at creation.
    public var contentHash: String
    public var status: ProposalStatus
    /// When it stopped being pending.
    public var decidedAt: Date?
    /// The owner's words when they declined.
    public var declineReason: String?

    public init(
        id: ProposalID, change: PolicyLoosen, from: String?, cwd: String?, createdAt: Date,
        contentHash: String, status: ProposalStatus = .pending, decidedAt: Date? = nil, declineReason: String? = nil
    ) {
        self.id = id
        self.change = change
        self.from = from
        self.cwd = cwd
        self.createdAt = createdAt
        self.contentHash = contentHash
        self.status = status
        self.decidedAt = decidedAt
        self.declineReason = declineReason
    }

    /// The hash of what this row holds now. Differs from `contentHash`
    /// when the row was edited after rvd created it.
    public var currentHash: String {
        LoosenProposalLedger.contentHash(id: id, change: change, from: from, cwd: cwd)
    }

    /// The first 12 hex digits of `contentHash`: what the owner compares.
    public var fingerprint: String { String(contentHash.prefix(12)) }
}

public enum LoosenProposalError: Error, Sendable, Equatable {
    /// The change is malformed (`PolicyLoosen.problem`).
    case invalid(String)
    case notFound
    /// The proposal was already decided or expired.
    case notPending(ProposalStatus)
    /// Its content no longer hashes to what the owner was shown.
    case changed
    /// Too many proposals wait already.
    case full
    /// The store could not be read or written.
    case unavailable
    /// The owner approved but the change could not be applied; nothing
    /// was marked approved.
    case applyFailed(String)
}

/// The pure rules for proposals: ids, the content hash, dedupe, caps,
/// expiry and the compare-and-set decision. No I/O.
public enum LoosenProposalLedger {
    /// Pending proposals one machine holds at most: an agent cannot bury
    /// the owner's list.
    public static let maxPending = 32
    /// Decided rows kept for `rv proposals` history.
    public static let maxDecided = 200
    /// A pending proposal expires after this long.
    public static let lifetime: TimeInterval = 7 * 24 * 3600
    /// Longest `from` or `cwd` label kept, in UTF-8 bytes.
    public static let maxLabelBytes = 256
    /// Longest decline reason kept, in UTF-8 bytes.
    public static let maxDeclineReasonBytes = 280

    /// SHA-256 over a length-prefixed encoding of every field the owner is
    /// shown, so no two different contents share an encoding.
    public static func contentHash(id: ProposalID, change: PolicyLoosen, from: String?, cwd: String?) -> String {
        var fields = ["rv.loosen.v1", id.rawValue]
        fields += change.canonicalFields
        fields.append(from.map { "+" + $0 } ?? "-")
        fields.append(cwd.map { "+" + $0 } ?? "-")
        var bytes = Data()
        for field in fields {
            let utf8 = Data(field.utf8)
            bytes.append(contentsOf: "\(utf8.count):".utf8)
            bytes.append(utf8)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Labels are cut to `maxLabelBytes` on a character boundary; empty is nil.
    static func label(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else {
            return nil
        }
        var cut = ""
        for character in text {
            if cut.utf8.count + String(character).utf8.count > maxLabelBytes { break }
            cut.append(character)
        }
        return cut
    }

    /// Pending rows older than `lifetime` become expired. Returns the rows
    /// and the ids that expired now.
    public static func sweep(_ records: [LoosenProposal], now: Date) -> ([LoosenProposal], [LoosenProposal]) {
        var expired: [LoosenProposal] = []
        let swept = records.map { record -> LoosenProposal in
            guard record.status == .pending, now.timeIntervalSince(record.createdAt) >= lifetime else { return record }
            var next = record
            next.status = .expired
            next.decidedAt = now
            expired.append(next)
            return next
        }
        return (swept, expired)
    }

    /// Adds a proposal, or returns the pending one with the same change and
    /// labels (`created == false`). Throws `.invalid` and `.full`.
    public static func propose(
        _ change: PolicyLoosen, from: String?, cwd: String?, records: [LoosenProposal], now: Date
    ) throws(LoosenProposalError) -> (proposal: LoosenProposal, records: [LoosenProposal], created: Bool) {
        if let problem = change.problem { throw .invalid(problem) }
        let from = label(from)
        let cwd = label(cwd)
        let (swept, _) = sweep(records, now: now)
        if let existing = swept.first(where: {
            $0.status == .pending && $0.change == change && $0.from == from && $0.cwd == cwd
        }) {
            return (existing, swept, false)
        }
        guard swept.filter({ $0.status == .pending }).count < maxPending else { throw .full }
        let id = ProposalID(number: (swept.map(\.id.number).max() ?? 0) + 1)
        let proposal = LoosenProposal(
            id: id, change: change, from: from, cwd: cwd, createdAt: now,
            contentHash: contentHash(id: id, change: change, from: from, cwd: cwd))
        return (proposal, prune(swept + [proposal]), true)
    }

    /// The pending proposal `id`, only while its content still hashes to
    /// `shownHash` (the hash the owner was shown) and to the hash rvd
    /// recorded when it created the row.
    public static func pending(
        _ id: ProposalID, shownHash: String, in records: [LoosenProposal]
    ) throws(LoosenProposalError) -> LoosenProposal {
        guard let record = records.last(where: { $0.id == id }) else { throw .notFound }
        guard record.status == .pending else { throw .notPending(record.status) }
        guard record.currentHash == record.contentHash, record.contentHash == shownHash else { throw .changed }
        if let problem = record.change.problem { throw .invalid(problem) }
        return record
    }

    /// Marks `id` decided, compare-and-set on `shownHash`.
    public static func decide(
        _ id: ProposalID, shownHash: String, to status: ProposalStatus, declineReason: String? = nil,
        records: [LoosenProposal], now: Date
    ) throws(LoosenProposalError) -> (proposal: LoosenProposal, records: [LoosenProposal]) {
        precondition(status == .approved || status == .rejected, "decide only approves or rejects")
        let (swept, _) = sweep(records, now: now)
        var record = try pending(id, shownHash: shownHash, in: swept)
        record.status = status
        record.decidedAt = now
        if status == .rejected {
            record.declineReason = declineReason.flatMap { reason in
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else { return nil }
                return String(trimmed.utf8.prefix(maxDeclineReasonBytes)) ?? String(trimmed.prefix(maxDeclineReasonBytes / 4))
            }
        }
        let next = swept.map { $0.id == id ? record : $0 }
        return (record, prune(next))
    }

    /// Keeps every pending row and the newest `maxDecided` decided rows.
    static func prune(_ records: [LoosenProposal]) -> [LoosenProposal] {
        let decided = records.filter { $0.status != .pending }
        guard decided.count > maxDecided else { return records }
        let drop = Set(decided.sorted { $0.id.number < $1.id.number }.prefix(decided.count - maxDecided).map(\.id))
        return records.filter { drop.contains($0.id) == false }
    }
}

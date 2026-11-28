import Foundation
import RVDomain
import RVFileStore

/// Durable loosen proposals (`loosen-proposals.jsonl`, owner-only, in the
/// rv config directory). Only rvd writes it: agents file proposals through
/// rvd, never by writing here, and the self-protection guard keeps them
/// out of rv's config directory. The content hash has no key, so a writer
/// who can edit this file can also recompute it: the hash is not what
/// protects a row. What does is that rvd applies a row only when its
/// content still hashes to the hash the owner was shown (`rv proposals`
/// prints it, and rvd's own prompt names it), checked again under the
/// store lock after the owner answers. A row edited after it was shown
/// is refused as changed.
public struct LoosenProposalStore: Sendable {
    public let configDirectory: URL
    private let file: FileLockedJSONLStore<LoosenProposal>

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
        self.file = FileLockedJSONLStore(
            fileURL: RVPolicyPaths.loosenProposalsFile(inConfigDir: configDirectory),
            lockURL: RVPolicyPaths.loosenProposalsLockFile(inConfigDir: configDirectory),
            directoryURL: configDirectory)
    }

    /// Runs `body` on the rows under the store lock and saves what it
    /// returns. A body that throws saves nothing. An unreadable file throws
    /// `.unavailable` and is never treated as empty.
    public func update<T>(
        _ body: ([LoosenProposal]) throws(LoosenProposalError) -> (T, [LoosenProposal]?)
    ) throws(LoosenProposalError) -> T {
        do {
            return try file.withLock {
                let records: [LoosenProposal]
                do { records = try file.loadChecked() } catch { throw LoosenProposalError.unavailable }
                let (value, next) = try body(records)
                if let next, next != records {
                    do { try file.save(next) } catch { throw LoosenProposalError.unavailable }
                }
                return value
            }
        } catch let error as LoosenProposalError {
            throw error
        } catch {
            throw .unavailable
        }
    }

    /// Files `change`. Returns the proposal, whether it is new, and the
    /// rows the expiry sweep ended now.
    public func propose(
        _ change: PolicyLoosen, from: String?, cwd: String?, now: Date
    ) throws(LoosenProposalError) -> (proposal: LoosenProposal, created: Bool, expired: [LoosenProposal]) {
        try update { records throws(LoosenProposalError) in
            let result = try LoosenProposalLedger.propose(change, from: from, cwd: cwd, records: records, now: now)
            return ((result.proposal, result.created, result.expired), result.records)
        }
    }

    /// Every row after the expiry sweep (persisted), oldest first, and the
    /// rows that expired during this call.
    public func list(now: Date) throws(LoosenProposalError) -> (all: [LoosenProposal], expiredNow: [LoosenProposal]) {
        try update { records throws(LoosenProposalError) in
            let (swept, expired) = LoosenProposalLedger.sweep(records, now: now)
            return ((swept, expired), swept)
        }
    }
}

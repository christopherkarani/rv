import Foundation
import RVDomain
import RVFileStore

/// Durable loosen proposals (`loosen-proposals.jsonl`, owner-only, in the
/// rv config directory). Only rvd writes it: agents file proposals through
/// rvd, never by writing here, and the self-protection guard keeps them
/// out of rv's config directory. A row edited behind rvd's back no longer
/// hashes to the hash rvd recorded, so it can never be approved.
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

    /// Files `change`. Returns the proposal and whether it is new.
    public func propose(
        _ change: PolicyLoosen, from: String?, cwd: String?, now: Date
    ) throws(LoosenProposalError) -> (proposal: LoosenProposal, created: Bool) {
        try update { records throws(LoosenProposalError) in
            let result = try LoosenProposalLedger.propose(change, from: from, cwd: cwd, records: records, now: now)
            return ((result.proposal, result.created), result.records)
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

import Foundation
import RVDomain

extension DenialLedgerRecord {
    /// A short code that names this row: six lowercase hex digits split
    /// three and three (`a7c-835`), from a SHA-256 of the row's fields.
    /// The same row always gets the same code, so `rv log` prints it and a
    /// reader can find the row again by it. Not an unlock code: those live
    /// only in rvd's memory and are never written to the ledger.
    public var code: String {
        var digest = RVSHA256Digest()
        digest.update(Array(codeInput.utf8))
        let hex = digest.digest().prefix(3).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(3)) + "-" + String(hex.suffix(3))
    }

    /// Every stored field, whole seconds for the time (what a JSONL line
    /// keeps), each ended by a NUL so no two rows share an input.
    private var codeInput: String {
        [
            String(Int64(timestamp.timeIntervalSince1970.rounded(.down))),
            host.rawValue,
            tool.rawValue,
            ruleID.rawValue,
            category.rawValue,
            path,
            observed ? "observed:\(wouldBe.rawValue)" : "enforced",
            session ?? "",
        ].map { $0 + "\u{0}" }.joined()
    }
}

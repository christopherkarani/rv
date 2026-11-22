import Foundation
import RVDomain

extension DenialLedgerRecord {
    /// A short code that names this row: six lowercase hex digits split
    /// three and three (`a7c-835`), from a SHA-256 of the row's fields.
    /// The same row always gets the same code, so `rv log` prints it and a
    /// reader can find the row again by it. Not an unlock code: those live
    /// only in rvd's memory and are never written to the ledger.
    public var code: String {
        RowCode.make([
            String(Int64(timestamp.timeIntervalSince1970.rounded(.down))),
            host.rawValue,
            tool.rawValue,
            ruleID.rawValue,
            category.rawValue,
            path,
            observed ? "observed:\(wouldBe.rawValue)" : "enforced",
            session ?? "",
        ])
    }
}

extension DecisionRecord {
    /// The same kind of code for a decision-log row that has no ledger
    /// row (the ledger is off, or pruned past its 200 rows). The decision
    /// log records no id of its own, and nothing the agent saw is in it.
    public var code: String {
        RowCode.make([
            "decision",
            String(Int64(time.timeIntervalSince1970.rounded(.down))),
            host.rawValue,
            tool.rawValue,
            verdict.rawValue,
            rule ?? "",
            command ?? "",
            path ?? "",
            session ?? "",
        ])
    }
}

private enum RowCode {
    /// Each field ended by a NUL so no two rows share an input.
    static func make(_ fields: [String]) -> String {
        var digest = RVSHA256Digest()
        digest.update(Array(fields.map { $0 + "\u{0}" }.joined().utf8))
        let hex = digest.digest().prefix(3).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(3)) + "-" + String(hex.suffix(3))
    }
}

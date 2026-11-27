import Foundation
import RVDomain

extension DenialLedgerRecord {
    /// A short code that names this row: six lowercase hex digits split
    /// three and three (`a7c-835`). From the call's `id` when the row has
    /// one, so it matches the decision-log row and survives the ledger's
    /// cap; else from a SHA-256 of the row's fields. The same row always
    /// gets the same code. Not an unlock code: those live only in rvd's
    /// memory and are never written down.
    public var code: String {
        if let id { return DecisionStamp.code(forID: id) }
        return RowCode.make([
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
    /// The same code for a decision-log row: from its `id`, or for a row
    /// written before ids, a SHA-256 of its fields.
    public var code: String {
        if let id { return DecisionStamp.code(forID: id) }
        return RowCode.make([
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

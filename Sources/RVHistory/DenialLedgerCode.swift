import Foundation
import RVDomain

extension DenialLedgerRecord {
    /// A short code that names this row's call: six lowercase hex digits
    /// split three and three (`a7c-835`), from the call's `id`, so it
    /// matches the decision-log row and survives the ledger's cap. Nil for
    /// a row with no id (the TTY, or written before ids). Not an unlock
    /// code: those live only in rvd's memory and are never written down.
    public var code: String? {
        id.map(DecisionStamp.code(forID:))
    }
}

extension DecisionRecord {
    /// The same code for a decision-log row; nil for a row with no id.
    public var code: String? {
        id.map(DecisionStamp.code(forID:))
    }
}

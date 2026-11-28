#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation

/// Block ledger (denials only, no command text) and the 7-day local
/// decision log (`DecisionLog`: every hook decision, command redacted).
public enum RVHistory {
    public static let maxRows = 200
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
}

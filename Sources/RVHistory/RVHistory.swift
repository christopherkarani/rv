#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation

/// Denial-only block ledger. Allows are never stored. Not command text.
public enum RVHistory {
    public static let maxRows = 200
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
}

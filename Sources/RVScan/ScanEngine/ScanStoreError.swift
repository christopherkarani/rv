import Foundation

/// Fail-closed session-store I/O shared by every extracting adapter.
///
/// Empty, non-UTF-8, JSON-less, or otherwise unreadable store bytes are an
/// error, never a successful empty event list. This enum unifies the five
/// historical per-host error enums (`CodexStoreError`, `CursorStoreError`,
/// `HermesStoreError`, `OpenClawStoreError`, `OpenCodeStoreError`), which were
/// identical case-for-case; the old names remain as typealiases so existing
/// callers and tests match unchanged.
public enum ScanStoreError: Error, Sendable, Equatable {
    /// `data` is empty, not UTF-8, wholly unreadable as JSONL, or not SQLite.
    case unreadable(sourcePath: String)
    /// Database opened but the host's query could not be prepared.
    case prepareFailed(sourcePath: String)
}

/// Compatibility alias for the pre-T1 per-host error enum.
public typealias CodexStoreError = ScanStoreError
/// Compatibility alias for the pre-T1 per-host error enum.
public typealias CursorStoreError = ScanStoreError
/// Compatibility alias for the pre-T1 per-host error enum.
public typealias HermesStoreError = ScanStoreError
/// Compatibility alias for the pre-T1 per-host error enum.
public typealias OpenClawStoreError = ScanStoreError
/// Compatibility alias for the pre-T1 per-host error enum.
public typealias OpenCodeStoreError = ScanStoreError

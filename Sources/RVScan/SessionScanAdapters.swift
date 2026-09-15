import RVDomain

/// Registered session-store adapters. Order matches `ScanRun`'s list.
public enum SessionScanAdapters {
    public static let all: [any SessionStoreAdapter] = [
        ClaudeSessionStoreAdapter(),
        PiStoreAdapter(),
        GrokStoreAdapter(),
        OpenCodeStoreAdapter(),
        OpenClawStoreAdapter(),
        HermesStoreAdapter(),
        CodexStoreAdapter(),
        CursorStoreAdapter(),
    ]

    /// Adapters for `host`, or every registered adapter when `host` is nil.
    public static func adapters(for host: ScanHostID?) -> [any SessionStoreAdapter] {
        guard let host else { return all }
        return all.filter { $0.host == host }
    }
}

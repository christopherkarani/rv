import RVDomain

/// Registered session-store adapters. Order matches the former CLI list.
public enum SessionScanAdapters {
    public static let all: [any SessionStoreAdapter] = [
        ClaudeSessionStoreAdapter(),
        PiStoreAdapter(),
        GrokStoreAdapter(),
        OpenCodeStoreAdapter(),
        OpenClawStoreAdapter(),
        HermesStoreAdapter(),
    ]

    public static func selected(hostFilter: ScanHostID?) -> [any SessionStoreAdapter] {
        guard let hostFilter else { return all }
        return all.filter { $0.host == hostFilter }
    }
}

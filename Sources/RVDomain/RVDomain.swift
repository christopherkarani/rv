#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

public enum RVDomain {}

public let dayOnePackIDs: [PackID] = [
    PackID(rawValue: "core.filesystem"),
    PackID(rawValue: "core.git"),
    PackID(rawValue: "system.disk"),
]

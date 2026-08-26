#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

/// Session-store discovery, bounds, adapters, extract, classify, and dedupe.
public enum RVScan {}

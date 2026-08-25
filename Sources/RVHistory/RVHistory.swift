#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

// Stub; history stays off by default; do not persist command text.
public enum RVHistory {}

#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

public enum RVPolicy {}

#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

/// Anonymous product analytics (PostHog). Off unless `analytics.enabled` is true in config.json.
public enum RVAnalytics {}

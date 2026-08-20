#if !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

/// Anonymous product analytics (PostHog). Opt-out via `analytics.enabled` in config.json.
public enum RVAnalytics {}

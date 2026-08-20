/// Seam for future disclosure UX (setup line, doctor row, CLI help).
///
/// v1 is silent: this type intentionally has no TTY or doctor surface.
/// Filling it later must not require changing PostHog transport.
public enum AnalyticsNotice: Sendable {
    /// Reserved. Returns nil until disclosure is product-approved.
    public static func setupLine() -> String? { nil }

    /// Reserved. Returns nil until disclosure is product-approved.
    public static func doctorLine(isEnabled: Bool) -> String? {
        _ = isEnabled
        return nil
    }
}

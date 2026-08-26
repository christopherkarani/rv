/// Measurable gates for later promotion to guarded Auto-review (OPE-253).
/// Shadow mode does not apply these; they exist so a later ticket can
/// compare recorded shadow metrics against a published bar.
///
/// Do not implement Auto-review or the $20 trial here.
public enum AutoReviewPromotionThresholds: Sendable {
    /// Shadow allow against human/deterministic deny, as a fraction of compared samples.
    public static let maximumFalseAllowRate: Double = 0.01

    /// Fraction of review-eligible actions that no longer need a human interruption.
    public static let minimumHumanInterruptionReduction: Double = 0.25

    /// Fraction of shadow decisions that match the later human decision.
    public static let minimumHumanAgreementRate: Double = 0.90

    /// Completed shadow reviews required before promotion can be considered.
    public static let minimumSampleSize: Int = 500
}

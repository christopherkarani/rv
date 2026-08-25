import RVDomain

/// Shadow coordinator. Invokes an `ActionReviewer` only for
/// `HardPolicyDecision.reviewEligible`. The live decision is the
/// deterministic/human projection of hard policy and is never combined
/// with model output (`ReviewBind.apply` is not on this path).
public enum ShadowReviewRunner: Sendable {
    /// Deterministic/human live decision. Reviewer output cannot change this.
    public static func liveDecision(from hardDecision: HardPolicyDecision) -> BoundReview {
        switch hardDecision {
        case .hardAllow:
            return .allow
        case .hardDeny(let deny):
            return .deny(deny)
        case .mandatoryHuman(let deny):
            return .mandatoryHuman(deny)
        case .reviewEligible(let fallback):
            return .mandatoryHuman(fallback)
        }
    }

    /// Evaluates through `ActionPolicyEngine`, then shadows that verdict.
    /// The runner still invokes the reviewer only for `reviewEligible`.
    public static func run(
        action: ProposedAction,
        context: ReviewContext,
        policy: EffectiveActionPolicy,
        reviewer: some ActionReviewer
    ) async -> ShadowReviewResult {
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: context,
            policy: policy
        )
        return await run(
            hardDecision: verdict.decision,
            request: ReviewRequest(action: action, context: context),
            reviewer: reviewer
        )
    }

    /// Runs a shadow review when eligible. Always returns `live` unchanged.
    public static func run(
        hardDecision: HardPolicyDecision,
        request: ReviewRequest,
        reviewer: some ActionReviewer
    ) async -> ShadowReviewResult {
        let live = liveDecision(from: hardDecision)
        guard case .reviewEligible = hardDecision else {
            return ShadowReviewResult(
                live: live,
                shadow: skippedRecord(providerID: reviewer.providerID, live: live, request: request)
            )
        }

        let clock = ContinuousClock()
        let started = clock.now
        let review: Result<ActionReview, ActionReviewerError>
        do {
            review = .success(try await reviewer.review(request))
        } catch let error as ActionReviewerError {
            review = .failure(error)
        } catch {
            review = .failure(.unsupported)
        }
        let latency = nanoseconds(clock.now - started)
        return ShadowReviewResult(
            live: live,
            shadow: recorded(
                providerID: reviewer.providerID,
                live: live,
                review: review,
                latencyNanoseconds: latency,
                request: request
            )
        )
    }

    private static func skippedRecord(
        providerID: ReviewerProviderID,
        live: BoundReview,
        request: ReviewRequest
    ) -> ShadowReviewRecord {
        ShadowReviewRecord(
            providerID: providerID,
            invoked: false,
            decision: nil,
            confidence: nil,
            rationaleCategory: nil,
            liveOutcome: ShadowLiveOutcome(live),
            latencyNanoseconds: 0,
            disagreesWithLive: false,
            missingContextReasons: ShadowMissingContext.reasons(in: request),
            modelUnavailable: false
        )
    }

    private static func recorded(
        providerID: ReviewerProviderID,
        live: BoundReview,
        review: Result<ActionReview, ActionReviewerError>,
        latencyNanoseconds: UInt64,
        request: ReviewRequest
    ) -> ShadowReviewRecord {
        switch review {
        case .success(let actionReview):
            return ShadowReviewRecord(
                providerID: providerID,
                invoked: true,
                decision: actionReview.decision,
                confidence: actionReview.confidence,
                rationaleCategory: actionReview.rationaleCategory,
                liveOutcome: ShadowLiveOutcome(live),
                latencyNanoseconds: latencyNanoseconds,
                disagreesWithLive: ShadowDisagreement.disagrees(
                    live: live,
                    decision: actionReview.decision
                ),
                missingContextReasons: ShadowMissingContext.reasons(in: request),
                modelUnavailable: false
            )
        case .failure:
            return ShadowReviewRecord(
                providerID: providerID,
                invoked: true,
                decision: nil,
                confidence: nil,
                rationaleCategory: nil,
                liveOutcome: ShadowLiveOutcome(live),
                latencyNanoseconds: latencyNanoseconds,
                disagreesWithLive: false,
                missingContextReasons: ShadowMissingContext.reasons(in: request),
                modelUnavailable: true
            )
        }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(clamping: max(0, components.seconds))
        let fromAttoseconds = UInt64(clamping: max(0, components.attoseconds / 1_000_000_000))
        return seconds &* 1_000_000_000 &+ fromAttoseconds
    }
}

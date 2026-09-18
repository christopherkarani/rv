import Foundation
import Testing
@testable import RVDomain

@Suite("EvaluationResultBoundReview")
struct EvaluationResultBoundReviewTests {
    private let deny = ActionPolicyEngine.Builtin.remoteBranchAsk
    private let packDeny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )

    @Test func boundReview_defaultsToNil() {
        let result = EvaluationResult(outcome: .plain)
        #expect(result.boundReview == nil)
    }

    @Test func boundReview_carriesMandatoryHumanInProcess() {
        let result = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push --force origin feature"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
        #expect(result.boundReview == .mandatoryHuman(deny))
        #expect(result.decision == .deny(deny))
    }

    @Test func boundReview_isOmittedFromCodableWire() throws {
        let result = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push --force origin feature"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
        let data = try JSONEncoder().encode(result)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("boundReview") == false)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.contains("boundReview") == false)

        let decoded = try JSONDecoder().decode(EvaluationResult.self, from: data)
        #expect(decoded.boundReview == nil)
        #expect(decoded.decision == .deny(deny))
        #expect(decoded.matchingView == MatchingView("git push --force origin feature"))
    }

    @Test func liveEvaluation_alwaysAttachesPackProjection() {
        let unbound = EvaluationResult(outcome: .plain)
        let live = unbound.live
        #expect(live.bound == .allow)
        #expect(BoundReview.packProjected(from: unbound) == live.bound)
        #expect(unbound.boundReview == nil)
    }

    @Test func liveEvaluation_fieldWinsOverPackProjection() {
        let result = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push --force origin feature"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
        #expect(result.live.bound == .mandatoryHuman(deny))
        #expect(result.live.result.boundReview == .mandatoryHuman(deny))
        #expect(result.live.wire.boundReview == nil)
    }

    @Test func evaluationResult_wireDropsBoundAndLiveRebuildsPackProjection() throws {
        let result = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push --force origin feature"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
        #expect(result.wire.boundReview == nil)
        let live = result.live
        let data = try JSONEncoder().encode(live.wire)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("boundReview") == false)
        let decoded = try JSONDecoder().decode(EvaluationResult.self, from: data)
        #expect(decoded.boundReview == nil)
        #expect(decoded.live.bound == .deny(deny))
        #expect(decoded.live.bound == BoundReview.packProjected(from: decoded))
    }

    @Test(arguments: [
        LiveBindRow(
            label: "pack allow",
            result: EvaluationResult(outcome: .plain, matchingView: MatchingView("git status")),
            expected: .allow
        ),
        LiveBindRow(
            label: "pack indeterminate",
            result: EvaluationResult(
                outcome: .indeterminate(.commandTooLarge),
                matchingView: MatchingView("huge")
            ),
            expected: .allow
        ),
    ])
    func live_packFallbackMatchesPackProjected(_ row: LiveBindRow) {
        #expect(row.result.live.bound == row.expected, Comment(rawValue: row.label))
        #expect(
            row.result.live.bound == BoundReview.packProjected(from: row.result),
            Comment(rawValue: row.label)
        )
        #expect(row.result.boundReview == nil, Comment(rawValue: row.label))
    }

    @Test func live_packDenyKeepsFieldNilForPolicyGate() {
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(result.boundReview == nil)
        #expect(HookAuthorization.policyGateAccess(for: result) == .consider)
        #expect(result.live.bound == .deny(packDeny))
    }
}

struct LiveBindRow: Sendable {
    let label: String
    let result: EvaluationResult
    let expected: BoundReview
}

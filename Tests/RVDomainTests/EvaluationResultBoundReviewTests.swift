import Foundation
import Testing
@testable import RVDomain

@Suite("EvaluationResultBoundReview")
struct EvaluationResultBoundReviewTests {
    private let deny = ActionPolicyEngine.Builtin.remoteBranchAsk

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
}

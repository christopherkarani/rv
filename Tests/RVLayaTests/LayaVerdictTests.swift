import Foundation
import Testing
@testable import RVLaya

@Suite("LayaVerdict wire format and labels")
struct LayaVerdictTests {
    /// Bytes produced by the pre-refactor String-keyed LayaVerdict.
    static let pinned = #"{"checkpoint":"ck","choice":"review","latencyMilliseconds":12.5,"malicious":0.25,"probabilities":{"allow":0.25,"block":0.25,"review":0.5},"risk":0.5,"riskScore":0.5,"truncated":true}"#

    static let verdict = LayaVerdict(
        choice: .review,
        probabilities: [.allow: 0.25, .review: 0.5, .block: 0.25],
        riskScore: 0.5, malicious: 0.25, risk: 0.5,
        checkpoint: "ck", latencyMilliseconds: 12.5, truncated: true
    )

    @Test func encodesToPinnedBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(Self.verdict), as: UTF8.self) == Self.pinned)
    }

    @Test func decodesPinnedLiteral() throws {
        let decoded = try JSONDecoder().decode(LayaVerdict.self, from: Data(Self.pinned.utf8))
        #expect(decoded == Self.verdict)
    }

    @Test func decodesLegacyLiteralWithoutTruncated() throws {
        let legacy = #"{"checkpoint":"ck","choice":"block","latencyMilliseconds":1,"malicious":0,"probabilities":{"allow":0.1,"block":0.8,"review":0.1},"risk":0.85,"riskScore":0.5}"#
        let decoded = try JSONDecoder().decode(LayaVerdict.self, from: Data(legacy.utf8))
        #expect(decoded.choice == .block)
        #expect(decoded.probabilities[.block] == 0.8)
        #expect(decoded.truncated == false)
    }

    @Test func unknownChoiceInPersistedVerdictFailsDecode() {
        let bad = Self.pinned.replacingOccurrences(of: #""choice":"review""#, with: #""choice":"revue""#)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LayaVerdict.self, from: Data(bad.utf8))
        }
    }

    @Test func guardQuestionsLabelsParse() throws {
        #expect(try LayaQuestions.guardQuestions.actionLabels() == [.allow, .review, .block])
    }

    @Test func respelledGuardQuestionLabelFailsLoading() {
        var questions = LayaQuestions.guardQuestions
        questions.action.options[2].label = "blok"
        #expect(throws: LayaError.self) { try questions.actionLabels() }
    }

    @Test func unknownConfigLabelFailsLoading() {
        #expect(throws: LayaError.self) {
            try LayaVerdict.Action.parse(labels: ["allow", "review", "deny"])
        }
    }
}

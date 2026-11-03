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

    /// A label set without `block` would score P(block) as 0: fail-open.
    @Test(arguments: [["allow", "review"], ["allow", "allow", "block"], ["allow", "review", "block", "block"]])
    func incompleteOrDuplicatedLabelsFailLoading(labels: [String]) {
        #expect(throws: LayaError.self) { try LayaVerdict.Action.parse(labels: labels) }
    }

    @Test func guardQuestionsWithoutBlockFailLoading() {
        var questions = LayaQuestions.guardQuestions
        questions.action.options.removeLast()
        #expect(throws: LayaError.self) { try questions.actionLabels() }
    }

    #if canImport(CoreML)
    /// AC-004 end to end: the bundle's config labels are checked at load,
    /// before any model file is touched.
    @Test func fineTunedBundleWithUnknownLabelFailsLoading() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("laya-labels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model":{"vocab":{},"merges":[]}}"#.utf8)
            .write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data(#"{"labels":["allow","review","deny"]}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        #expect {
            _ = try FineTunedJudge(bundleDir: dir)
        } throws: { error in
            guard case LayaError.badBundle(let why) = error else { return false }
            return why.contains("deny")
        }
    }
    #endif
}

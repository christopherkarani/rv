import Foundation
import Testing
@testable import RVDomain

/// Golden frames: encoded EvaluationResult bytes captured verbatim from the
/// pre-outcome implementation. Encoders must keep producing this wire shape.
private enum GoldenFrame {
    static let plain =
        #"{"matchingView":"","decision":{"decision":"allow"},"quickRejected":false}"#
    static let quickRejected =
        #"{"decision":{"decision":"allow"},"matchingView":"ls","quickRejected":true}"#
    static let hitWithSafe =
       #"{"decision":{"decision":"allow"},"matched":{"regex":"git\\s+reset\\s+--hard","explanation":"Discards every uncommitted change.","ruleID":"core.git:reset-hard","searchText":"git reset --hard","packID":"core.git","severity":"critical","patternName":"reset-hard","span":{"start":0,"end":16},"matchedText":"git reset --hard","reason":"git reset --hard destroys uncommitted changes"},"matchedSafe":{"packID":"core.git","patternName":"checkout-new-branch"},"quickRejected":false,"matchingView":"git reset --hard"}"#
    static let hitNoSafe =
       #"{"matchingView":"git reset --hard","matched":{"regex":"git\\s+reset\\s+--hard","explanation":"Discards every uncommitted change.","ruleID":"core.git:reset-hard","searchText":"git reset --hard","packID":"core.git","severity":"critical","patternName":"reset-hard","span":{"start":0,"end":16},"matchedText":"git reset --hard","reason":"git reset --hard destroys uncommitted changes"},"decision":{"decision":"allow"},"quickRejected":false}"#
    static let safeOnly =
        #"{"matchedSafe":{"packID":"core.git","patternName":"checkout-new-branch"},"matchingView":"git checkout -b new","decision":{"decision":"allow"},"quickRejected":false}"#
    static let deny =
        #"{"matchingView":"git reset --hard","matched":{"regex":"git\\s+reset\\s+--hard","explanation":"Discards every uncommitted change.","ruleID":"core.git:reset-hard","searchText":"git reset --hard","packID":"core.git","severity":"critical","patternName":"reset-hard","span":{"start":0,"end":16},"matchedText":"git reset --hard","reason":"git reset --hard destroys uncommitted changes"},"decision":{"reason":"git reset --hard destroys uncommitted changes","decision":"deny","ruleID":"core.git:reset-hard"},"quickRejected":false}"#
    static let indeterminate =
        #"{"matchingView":"git status","decision":{"decision":"indeterminate","indeterminateReason":"commandTooLarge"},"quickRejected":false}"#
    static let unicodeView =
        #"{"matchedSafe":{"packID":"core.filesystem","patternName":"café"},"matchingView":"echo «ünïcode» ✓","decision":{"decision":"allow"},"quickRejected":false}"#
}

private let goldenMatch = RuleMatch(
    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
    packID: .coreGit,
    patternName: "reset-hard",
    severity: .critical,
    reason: "git reset --hard destroys uncommitted changes",
    explanation: "Discards every uncommitted change.",
    regex: #"git\s+reset\s+--hard"#,
    span: MatchSpan(start: 0, end: 16),
    matchedText: "git reset --hard",
    searchText: "git reset --hard"
)

@Suite("EvaluationResultWireTests")
struct EvaluationResultWireTests {
    private func sample(_ name: String) -> EvaluationResult {
        switch name {
        case "plain":
            return EvaluationResult(outcome: .plain)
        case "quickRejected":
            return EvaluationResult(outcome: .quickRejected, matchingView: MatchingView("ls"))
        case "hitWithSafe":
            return EvaluationResult(
                outcome: .hit(
                    goldenMatch,
                    safe: SafeMatch(packID: .coreGit, patternName: "checkout-new-branch")
                ),
                matchingView: MatchingView("git reset --hard")
            )
        case "hitNoSafe":
            return EvaluationResult(
                outcome: .hit(goldenMatch, safe: nil),
                matchingView: MatchingView("git reset --hard")
            )
        case "safeOnly":
            return EvaluationResult(
                outcome: .safeOnly(SafeMatch(packID: .coreGit, patternName: "checkout-new-branch")),
                matchingView: MatchingView("git checkout -b new")
            )
        case "deny":
            return EvaluationResult(
                outcome: .deny(
                    Deny(
                        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                        reason: "git reset --hard destroys uncommitted changes"
                    ),
                    matched: goldenMatch
                ),
                matchingView: MatchingView("git reset --hard")
            )
        case "indeterminate":
            return EvaluationResult(
                outcome: .indeterminate(.commandTooLarge),
                matchingView: MatchingView("git status")
            )
        default:
            return EvaluationResult(
                outcome: .safeOnly(SafeMatch(packID: .coreFilesystem, patternName: "café")),
                matchingView: MatchingView("echo «ünïcode» ✓")
            )
        }
    }

    @Test("encode matches the pinned pre-outcome wire bytes")
    func encodeMatchesGoldenFrames() throws {
        let pairs: [(name: String, frame: String)] = [
            ("plain", GoldenFrame.plain),
            ("quickRejected", GoldenFrame.quickRejected),
            ("hitWithSafe", GoldenFrame.hitWithSafe),
            ("hitNoSafe", GoldenFrame.hitNoSafe),
            ("safeOnly", GoldenFrame.safeOnly),
            ("deny", GoldenFrame.deny),
            ("indeterminate", GoldenFrame.indeterminate),
            ("unicodeView", GoldenFrame.unicodeView),
        ]
        for pair in pairs {
            let encoded = try JSONEncoder().encode(sample(pair.name))
            let actualObject = try #require(
                JSONSerialization.jsonObject(with: encoded) as? NSDictionary
            )
            let frameData = Data(pair.frame.utf8)
            let expectedObject = try #require(
                JSONSerialization.jsonObject(with: frameData) as? NSDictionary
            )
            #expect(actualObject == expectedObject, "golden frame mismatch: \(pair.name)")

            let json = String(decoding: encoded, as: UTF8.self)
            #expect(json.contains(#""quickRejected":"#))
            #expect(json.contains("«ünïcode»") == (pair.name == "unicodeView"))
        }
    }

    @Test("hit omits absent safe key like HEAD")
    func hitOmitsAbsentSafeKey() throws {
        let encoded = try JSONEncoder().encode(sample("hitNoSafe"))
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("matchedSafe"))
    }

    @Test("HEAD frame decodes to the equivalent outcome")
    func headFrameDecodesToEquivalentOutcome() throws {
        #expect(try decode(GoldenFrame.plain).outcome == .plain)

        let decodedQuickReject = try decode(GoldenFrame.quickRejected)
        #expect(decodedQuickReject.outcome == .quickRejected)
        #expect(decodedQuickReject.matchingView == MatchingView("ls"))

        let decodedHit = try decode(GoldenFrame.hitWithSafe)
        #expect(
            decodedHit.outcome
                == .hit(
                    goldenMatch,
                    safe: SafeMatch(packID: .coreGit, patternName: "checkout-new-branch")
                )
        )

        #expect(try decode(GoldenFrame.hitNoSafe).outcome == .hit(goldenMatch, safe: nil))

        let decodedSafeOnly = try decode(GoldenFrame.safeOnly)
        #expect(
            decodedSafeOnly.outcome
                == .safeOnly(SafeMatch(packID: .coreGit, patternName: "checkout-new-branch"))
        )

        let decodedDeny = try decode(GoldenFrame.deny)
        #expect(
            decodedDeny.outcome
                == .deny(
                    Deny(
                        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                        reason: "git reset --hard destroys uncommitted changes"
                    ),
                    matched: goldenMatch
                )
        )

        let decodedIndeterminate = try decode(GoldenFrame.indeterminate)
        #expect(decodedIndeterminate.outcome == .indeterminate(.commandTooLarge))
    }

    @Test("matchingView absent decodes to empty view")
    func missingMatchingViewDefaultsToEmpty() throws {
        let frame =
            #"{"decision":{"decision":"allow"},"quickRejected":false}"#
        let decoded = try decode(frame)
        #expect(decoded.matchingView == MatchingView(""))
        #expect(decoded.outcome == .plain)
    }

    @Test("invalid field combinations throw a typed error")
    func invalidCombinationsThrow() {
        let combos: [(Decision, Bool, Bool, Bool)] = [
            (.allow, true, false, true),
            (.allow, false, true, true),
            (.indeterminate(.commandTooLarge), true, false, false),
            (.indeterminate(.budgetExhausted), false, true, true),
            (
                .deny(Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")),
                false,
                true,
                false
            ),
            (
                .deny(Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")),
                true,
                false,
                true
            ),
        ]
        for combo in combos {
            let frame = Self.frame(decision: combo.0, matched: combo.1, matchedSafe: combo.2, quickRejected: combo.3)
            #expect(throws: EvaluationResultDecodingError.self) {
                try decode(frame)
            }
        }
    }

    @Test("round trip preserves every outcome")
    func roundTripPreservesOutcomes() throws {
        let results: [EvaluationResult] = [
            sample("plain"),
            sample("quickRejected"),
            sample("hitWithSafe"),
            sample("hitNoSafe"),
            sample("safeOnly"),
            sample("deny"),
            sample("indeterminate"),
        ]
        for result in results {
            let data = try JSONEncoder().encode(result)
            let decoded = try JSONDecoder().decode(EvaluationResult.self, from: data)
            #expect(decoded == result)
        }
    }

    @Test("outcomes project onto decision and legacy fields")
    func outcomesProjectOntoLegacyFields() {
        #expect(sample("plain").outcome.decision == .allow)
        #expect(sample("quickRejected").outcome.quickRejected)
        #expect(sample("quickRejected").outcome.decision == .allow)

        let hit = sample("hitWithSafe").outcome
        #expect(hit.decision == .allow)
        #expect(hit.matched?.ruleID.rawValue == "core.git:reset-hard")
        #expect(hit.matchedSafe?.patternName == "checkout-new-branch")

        let safeOnly = sample("safeOnly").outcome
        #expect(safeOnly.matched == nil)
        #expect(safeOnly.matchedSafe != nil)

        let denied = sample("deny").outcome
        #expect(denied.decision == .deny(Deny(ruleID: .init(pack: .coreGit, pattern: "reset-hard"), reason: "git reset --hard destroys uncommitted changes")))
        #expect(denied.matched?.ruleID.rawValue == "core.git:reset-hard")

        let incomplete = sample("indeterminate").outcome
        #expect(incomplete.decision == .indeterminate(.commandTooLarge))
        #expect(!incomplete.quickRejected)
    }

    private static func frame(
        decision: Decision,
        matched: Bool,
        matchedSafe: Bool,
        quickRejected: Bool
    ) -> String {
        var parts: [String] = [#""decision":"# + decisionJSON(decision)]
        if matched {
            parts.append(
                #""matched":{"ruleID":"core.git:stash-drop","packID":"core.git","patternName":"stash-drop","severity":"medium","reason":"drops one stash"}"#
            )
        }
        if matchedSafe {
            parts.append(#""matchedSafe":{"packID":"core.git","patternName":"keep"}"#)
        }
        parts.append(#""quickRejected":\#(quickRejected ? "true" : "false")"#)
        parts.append(#""matchingView":"git stash drop""#)
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func decisionJSON(_ decision: Decision) -> String {
        switch decision {
        case .allow:
            return #"{"decision":"allow"}"#
        case .deny(let deny):
            return #"{"decision":"deny","ruleID":"\#(deny.ruleID.rawValue)","reason":"\#(deny.reason)"}"#
        case .indeterminate(let reason):
            return #"{"decision":"indeterminate","indeterminateReason":"\#(reason.rawValue)"}"#
        }
    }

    private func decode(_ frame: String) throws -> EvaluationResult {
        try JSONDecoder().decode(EvaluationResult.self, from: Data(frame.utf8))
    }
}

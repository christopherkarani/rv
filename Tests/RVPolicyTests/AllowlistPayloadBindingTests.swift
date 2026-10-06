import Foundation
import Testing
import RVDomain
@testable import RVPolicy

// M-07: exact-command allowlist entries bind the masked payload digest so
// the allowlist cannot bypass the ephemeral grant binding.

struct AllowlistPayloadBindingTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let maskedView = MatchingView("echo    ")

    private static func boundEntry(_ segments: [String]) -> AllowlistEntry {
        AllowlistEntry(
            selector: .exactCommand(Self.maskedView),
            reason: "test",
            addedAt: Self.now,
            maskedPayloadDigest: maskedPayloadContentDigest(segments)
        )
    }

    @Test func contentDigestIsDeterministicAndDiscriminating() {
        #expect(maskedPayloadContentDigest(["aaa"]) == maskedPayloadContentDigest(["aaa"]))
        #expect(maskedPayloadContentDigest(["aaa"]) != maskedPayloadContentDigest(["bbb"]))
        #expect(maskedPayloadContentDigest([]) == maskedPayloadContentDigest([]))
        #expect(maskedPayloadContentDigest(["a", "b"]) != maskedPayloadContentDigest(["a b"]))
        #expect(maskedPayloadContentDigest(["a", ""]) != maskedPayloadContentDigest(["a"]))
    }

    @Test func boundEntryMatchesIdenticalPayload() {
        let snapshot = AllowlistSnapshot(entries: [Self.boundEntry(["aaa"])])
        #expect(snapshot.matches(ruleID: nil, matchingView: Self.maskedView, now: Self.now, maskedSegments: ["aaa"]))
    }

    @Test func boundEntryRejectsDifferentPayloadSameView() {
        let snapshot = AllowlistSnapshot(entries: [Self.boundEntry(["aaa"])])
        #expect(
            snapshot.matches(ruleID: nil, matchingView: Self.maskedView, now: Self.now, maskedSegments: ["bbb"])
                == false
        )
    }

    @Test func boundEntryRejectsUnknownSpend() {
        let snapshot = AllowlistSnapshot(entries: [Self.boundEntry(["aaa"])])
        #expect(
            snapshot.matches(ruleID: nil, matchingView: Self.maskedView, now: Self.now, maskedSegments: nil)
                == false
        )
    }

    @Test func legacyEntryFailsClosedOnMaskedSpend() {
        let legacy = AllowlistEntry(selector: .exactCommand(Self.maskedView), reason: "legacy", addedAt: Self.now)
        #expect(legacy.maskedPayloadDigest == nil)
        let snapshot = AllowlistSnapshot(entries: [legacy])
        #expect(
            snapshot.matches(ruleID: nil, matchingView: Self.maskedView, now: Self.now, maskedSegments: ["aaa"])
                == false
        )
        #expect(snapshot.matches(ruleID: nil, matchingView: Self.maskedView, now: Self.now, maskedSegments: []))
        #expect(snapshot.matches(ruleID: nil, matchingView: Self.maskedView, now: Self.now, maskedSegments: nil))
    }

    @Test func ruleEntriesIgnorePayloadBinding() throws {
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        let snapshot = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .rule(ruleID), reason: "rule", addedAt: Self.now),
        ])
        #expect(snapshot.matches(ruleID: ruleID, matchingView: Self.maskedView, now: Self.now, maskedSegments: ["aaa"]))
        #expect(
            snapshot.matches(ruleID: ruleID, matchingView: Self.maskedView, now: Self.now, maskedSegments: nil)
        )
    }

    @Test func tomlRoundTripsPayloadDigest() throws {
        let entries = [Self.boundEntry(["aaa"])]
        let rendered = AllowlistTOML.render(entries)
        #expect(rendered.contains("payload_digest"))
        let parsed = try AllowlistTOML.parse(rendered)
        #expect(parsed == entries)
    }

    @Test func tomlOmitsNilDigestAndParsesLegacy() throws {
        let legacy = AllowlistEntry(selector: .exactCommand(Self.maskedView), reason: "legacy", addedAt: Self.now)
        #expect(AllowlistTOML.render([legacy]).contains("payload_digest") == false)
        let parsed = try AllowlistTOML.parse("""
        [[allow]]
        exact_command = "echo    "
        reason = "legacy"
        added_at = "2023-11-14T22:13:20Z"
        """)
        #expect(parsed.count == 1)
        #expect(parsed[0].maskedPayloadDigest == nil)
    }

    @Test func policyGateDecisionThreadsBinding() {
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "test"),
                matched: nil
            ),
            matchingView: Self.maskedView
        )
        let allowlist = AllowlistSnapshot(entries: [Self.boundEntry(["aaa"])])
        let cross = PolicyGate.decision(
            for: denied, cwd: wd("/tmp/ws"), allowlist: allowlist, grant: .none, now: Self.now,
            maskedSegments: ["bbb"]
        )
        #expect(cross.override == .none)
        let same = PolicyGate.decision(
            for: denied, cwd: wd("/tmp/ws"), allowlist: allowlist, grant: .none, now: Self.now,
            maskedSegments: ["aaa"]
        )
        #expect(same.override == .allowlist)
    }
}

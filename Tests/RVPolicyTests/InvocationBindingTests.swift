import Foundation
import Testing
import RVDomain
@testable import RVPolicy

// B1: grants and exact-command allowlist entries bind the erased
// invocation prefix (wrappers, assignments, argv0 path), so one approval
// never covers an unreviewed `sudo`/`env`/path/assignment variant.

struct InvocationBindingTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let view = MatchingView("git reset --hard")

    // MARK: - Grant fingerprint

    @Test func grantFingerprintIsDeterministic() {
        let first = grantFingerprint(Self.view, invocationPrefix: ["sudo"])
        #expect(first == grantFingerprint(Self.view, invocationPrefix: ["sudo"]))
        #expect(first.rawValue.count == 64)
    }

    @Test func grantFingerprintSeparatesErasedVariants() {
        let bare = grantFingerprint(Self.view, invocationPrefix: [])
        #expect(grantFingerprint(Self.view, invocationPrefix: ["sudo"]) != bare)
        #expect(grantFingerprint(Self.view, invocationPrefix: ["env LD_PRELOAD=x"]) != bare)
        #expect(grantFingerprint(Self.view, invocationPrefix: ["/bin/git"]) != bare)
        #expect(grantFingerprint(Self.view, invocationPrefix: ["FOO=bar"]) != bare)
        #expect(grantFingerprint(Self.view, invocationPrefix: ["sudo"]) != grantFingerprint(Self.view, invocationPrefix: ["env FOO=1"]))
    }

    // MARK: - Memory table

    @Test func plainPlantDoesNotSpendWrapped() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                matchingView: Self.view, cwd: wd("/tmp/ws"), codeHash: "b1-plain",
                now: Self.now, invocationPrefix: []
            ) == .planted
        )
        #expect(
            await table.consume(matchingView: Self.view, cwd: wd("/tmp/ws"), now: Self.now, invocationPrefix: ["sudo"])
                == false
        )
        // The rejected spend must not burn the grant.
        #expect(
            await table.consume(matchingView: Self.view, cwd: wd("/tmp/ws"), now: Self.now, invocationPrefix: [])
        )
    }

    @Test func wrappedPlantSpendsWrappedOnce() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                matchingView: Self.view, cwd: wd("/tmp/ws"), codeHash: "b1-wrapped",
                now: Self.now, invocationPrefix: ["sudo"]
            ) == .planted
        )
        #expect(
            await table.consume(matchingView: Self.view, cwd: wd("/tmp/ws"), now: Self.now, invocationPrefix: [])
                == false
        )
        #expect(
            await table.consume(matchingView: Self.view, cwd: wd("/tmp/ws"), now: Self.now, invocationPrefix: ["sudo"])
        )
        #expect(
            await table.consume(matchingView: Self.view, cwd: wd("/tmp/ws"), now: Self.now, invocationPrefix: ["sudo"])
                == false
        )
    }

    @Test func wrappedVariantsDoNotShare() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                matchingView: Self.view, cwd: wd("/tmp/ws"), codeHash: "b1-cross",
                now: Self.now, invocationPrefix: ["sudo"]
            ) == .planted
        )
        #expect(
            await table.hasGrant(matchingView: Self.view, cwd: wd("/tmp/ws"), now: Self.now, invocationPrefix: ["env FOO=1"])
                == false
        )
        #expect(
            await table.consume(matchingView: Self.view, cwd: wd("/tmp/ws"), now: Self.now, invocationPrefix: ["sudo"])
        )
    }

    // MARK: - Allowlist

    private static func entry(invocationDigest: ContentPayloadDigest?) -> AllowlistEntry {
        AllowlistEntry(
            selector: .exactCommand(Self.view),
            reason: "test",
            addedAt: Self.now,
            invocationDigest: invocationDigest
        )
    }

    @Test func boundAllowlistEntryMatchesIdenticalInvocation() {
        let snapshot = AllowlistSnapshot(entries: [
            Self.entry(invocationDigest: maskedPayloadContentDigest(["sudo"]))
        ])
        #expect(snapshot.matches(
            ruleID: nil, matchingView: Self.view, now: Self.now, invocationPrefix: ["sudo"]
        ))
        #expect(
            snapshot.matches(
                ruleID: nil, matchingView: Self.view, now: Self.now, invocationPrefix: []
            ) == false
        )
        #expect(
            snapshot.matches(
                ruleID: nil, matchingView: Self.view, now: Self.now, invocationPrefix: nil
            ) == false
        )
    }

    @Test func legacyAllowlistEntryFailsClosedOnWrappedSpend() {
        let legacy = AllowlistEntry(selector: .exactCommand(Self.view), reason: "legacy", addedAt: Self.now)
        #expect(legacy.invocationDigest == nil)
        let snapshot = AllowlistSnapshot(entries: [legacy])
        #expect(
            snapshot.matches(
                ruleID: nil, matchingView: Self.view, now: Self.now, invocationPrefix: ["sudo"]
            ) == false
        )
        #expect(snapshot.matches(
            ruleID: nil, matchingView: Self.view, now: Self.now, invocationPrefix: []
        ))
        #expect(snapshot.matches(
            ruleID: nil, matchingView: Self.view, now: Self.now, invocationPrefix: nil
        ))
    }

    @Test func tomlRoundTripsInvocationDigest() throws {
        let entries = [Self.entry(invocationDigest: maskedPayloadContentDigest(["sudo"]))]
        let rendered = AllowlistTOML.render(entries)
        #expect(rendered.contains("invocation_digest"))
        let parsed = try AllowlistTOML.parse(rendered)
        #expect(parsed == entries)
    }

    @Test func consumingGrantThreadsInvocation() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                matchingView: Self.view, cwd: wd("/tmp/ws"), codeHash: "b1-gate",
                now: Self.now, invocationPrefix: []
            ) == .planted
        )
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "test"),
                matched: nil
            ),
            matchingView: Self.view
        )
        let cross = await PolicyGate.consumingGrant(
            for: denied, cwd: wd("/tmp/ws"), grants: table, now: Self.now, invocationPrefix: ["sudo"]
        )
        #expect(cross.override == .none)
        let same = await PolicyGate.consumingGrant(
            for: denied, cwd: wd("/tmp/ws"), grants: table, now: Self.now, invocationPrefix: []
        )
        #expect(same.override == .allowOnce)
    }
}

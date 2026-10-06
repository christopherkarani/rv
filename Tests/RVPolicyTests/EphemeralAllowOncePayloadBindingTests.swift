import Foundation
import Testing
import RVDomain
@testable import RVPolicy

// M-07: a grant minted for one hidden payload must not authorize another
// command with the same masked view. Grants bind (view + salted digest of
// the exact masked segments); spend requires equality.

struct EphemeralAllowOncePayloadBindingTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Masked view shared by `echo aaa` and `echo bbb`.
    private static let maskedView = MatchingView("echo    ")

    @Test func boundGrantSpendsForIdenticalPayload() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                matchingView: Self.maskedView, cwd: wd("/tmp/ws"), codeHash: "m7-same",
                now: Self.now, maskedSegments: ["aaa"]
            ) == .planted
        )
        #expect(
            await table.hasGrant(matchingView: Self.maskedView, cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: ["aaa"])
        )
        #expect(
            await table.consume(matchingView: Self.maskedView, cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: ["aaa"])
        )
    }

    @Test func boundGrantRejectsDifferentPayloadSameView() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                matchingView: Self.maskedView, cwd: wd("/tmp/ws"), codeHash: "m7-cross",
                now: Self.now, maskedSegments: ["aaa"]
            ) == .planted
        )
        #expect(
            await table.hasGrant(matchingView: Self.maskedView, cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: ["bbb"])
                == false
        )
        #expect(
            await table.consume(matchingView: Self.maskedView, cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: ["bbb"])
                == false
        )
        // The rejected spend must not burn the grant.
        #expect(
            await table.consume(matchingView: Self.maskedView, cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: ["aaa"])
        )
    }

    @Test func boundGrantRejectsUnknownSpend() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                matchingView: Self.maskedView, cwd: wd("/tmp/ws"), codeHash: "m7-unknown",
                now: Self.now, maskedSegments: ["aaa"]
            ) == .planted
        )
        #expect(
            await table.consume(matchingView: Self.maskedView, cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: nil)
                == false
        )
    }

    @Test func boundGrantForUnmaskedCommandSpends() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "m7-plain",
                now: Self.now, maskedSegments: []
            ) == .planted
        )
        #expect(
            await table.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: [])
        )
    }

    @Test func unboundGrantFailsClosedOnMaskedSpend() async {
        // TTY fingerprint plants carry no payload binding (daemon never sees
        // exact text there). They keep legacy behavior for unmasked spends
        // but must never authorize a payload-hidden command.
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                fingerprint: grantFingerprint(Self.maskedView, invocationPrefix: []), cwd: wd("/tmp/ws"),
                codeHash: "m7-tty", now: Self.now
            ) == .planted
        )
        #expect(
            await table.consume(matchingView: Self.maskedView, cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: ["aaa"])
                == false
        )
    }

    @Test func unboundGrantKeepsLegacyUnmaskedSpend() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                fingerprint: grantFingerprint("git reset --hard", invocationPrefix: []), cwd: wd("/tmp/ws"),
                codeHash: "m7-tty-plain", now: Self.now
            ) == .planted
        )
        #expect(
            await table.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: [])
        )
    }

    @Test func bindingsDoNotCrossTables() async {
        // Per-boot salt: the same payload binds differently per table.
        let first = EphemeralAllowOnceTable()
        let second = EphemeralAllowOnceTable()
        #expect(
            await first.plant(
                matchingView: Self.maskedView, cwd: wd("/tmp/ws"), codeHash: "m7-salt",
                now: Self.now, maskedSegments: ["aaa"]
            ) == .planted
        )
        #expect(
            await second.hasGrant(
                matchingView: Self.maskedView, cwd: wd("/tmp/ws"), now: Self.now, maskedSegments: ["aaa"]
            ) == false
        )
    }

    @Test func consumingGrantHonorsBinding() async {
        let table = EphemeralAllowOnceTable()
        #expect(
            await table.plant(
                matchingView: Self.maskedView, cwd: wd("/tmp/ws"), codeHash: "m7-gate",
                now: Self.now, maskedSegments: ["aaa"]
            ) == .planted
        )
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "test"),
                matched: nil
            ),
            matchingView: Self.maskedView
        )
        let cross = await PolicyGate.consumingGrant(
            for: denied, cwd: wd("/tmp/ws"), grants: table, now: Self.now, maskedSegments: ["bbb"]
        )
        #expect(cross.override == .none)
        guard case .deny = cross.result.decision else {
            Issue.record("cross-payload spend must stay denied")
            return
        }
        let same = await PolicyGate.consumingGrant(
            for: denied, cwd: wd("/tmp/ws"), grants: table, now: Self.now, maskedSegments: ["aaa"]
        )
        #expect(same.override == .allowOnce)
        #expect(same.result.decision == .allow)
    }
}

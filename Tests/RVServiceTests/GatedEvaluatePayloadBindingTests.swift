import Foundation
import Testing
import RVDomain
import RVEngine
import RVPolicy
@testable import RVService

// M-07 end to end: a grant planted for one hidden payload spends for the
// identical re-issue and denies a same-view command with another payload.

struct GatedEvaluatePayloadBindingTests {
    // Same masked view, different hidden payloads; the pack deny stays
    // grant-unlockable (interpreter-wrapped destructive inners hard-deny).
    private static let payloadA = #"echo "aaa" ; git reset --hard"#
    private static let payloadB = #"echo "bbb" ; git reset --hard"#
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func request(_ command: String) -> EvaluationRequest {
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs)
    }

    @Test func payloadPairSharesViewButNotSegments() {
        #expect(Normalize.matchingView(of: Self.payloadA) == Normalize.matchingView(of: Self.payloadB))
        #expect(Normalize.maskedSegments(of: Self.payloadA) != Normalize.maskedSegments(of: Self.payloadB))
    }

    @Test func boundGrantSpendsIdenticalPayload() async {
        let grants = EphemeralAllowOnceTable()
        let gated = GatedEvaluate()
        #expect(
            await grants.plant(
                matchingView: Normalize.matchingView(of: Self.payloadA),
                cwd: wd("/tmp/ws"),
                codeHash: "m7-e2e-same",
                now: Self.now,
                maskedSegments: Normalize.maskedSegments(of: Self.payloadA)
            ) == .planted
        )
        let applied = await gated.apply(
            Self.request(Self.payloadA),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: Self.now,
            allowlist: { .empty }
        )
        #expect(applied.decision == .allow)
    }

    @Test func boundGrantRejectsCrossPayloadSameView() async {
        let grants = EphemeralAllowOnceTable()
        let gated = GatedEvaluate()
        #expect(
            await grants.plant(
                matchingView: Normalize.matchingView(of: Self.payloadA),
                cwd: wd("/tmp/ws"),
                codeHash: "m7-e2e-cross",
                now: Self.now,
                maskedSegments: Normalize.maskedSegments(of: Self.payloadA)
            ) == .planted
        )
        let cross = await gated.apply(
            Self.request(Self.payloadB),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: Self.now,
            allowlist: { .empty }
        )
        guard case .deny = cross.decision else {
            Issue.record("cross-payload apply must deny, got \(cross.decision)")
            return
        }
        // The rejected spend must not burn the grant.
        let same = await gated.apply(
            Self.request(Self.payloadA),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: Self.now,
            allowlist: { .empty }
        )
        #expect(same.decision == .allow)
    }

    @Test func unboundGrantFailsClosedOnMaskedApply() async {
        // TTY fingerprint plants carry no binding: masked applies fail
        // closed until the attestation wire can carry a payload digest.
        let grants = EphemeralAllowOnceTable()
        let gated = GatedEvaluate()
        #expect(
            await grants.plant(
                fingerprint: commandFingerprint(Normalize.matchingView(of: Self.payloadA)),
                cwd: wd("/tmp/ws"),
                codeHash: "m7-e2e-tty",
                now: Self.now
            ) == .planted
        )
        let applied = await gated.apply(
            Self.request(Self.payloadA),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: Self.now,
            allowlist: { .empty }
        )
        guard case .deny = applied.decision else {
            Issue.record("unbound masked apply must deny, got \(applied.decision)")
            return
        }
    }

    @Test func allowlistBoundEntryThreadsThroughGate() async {
        let grants = EphemeralAllowOnceTable()
        let gated = GatedEvaluate()
        let snapshot = AllowlistSnapshot(entries: [
            AllowlistEntry(
                selector: .exactCommand(Normalize.matchingView(of: Self.payloadA)),
                reason: "test",
                addedAt: Self.now,
                maskedPayloadDigest: maskedPayloadContentDigest(
                    Normalize.maskedSegments(of: Self.payloadA))
            ),
        ])
        let cross = await gated.apply(
            Self.request(Self.payloadB),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: Self.now,
            allowlist: { snapshot }
        )
        guard case .deny = cross.decision else {
            Issue.record("cross-payload allowlist apply must deny, got \(cross.decision)")
            return
        }
        let same = await gated.apply(
            Self.request(Self.payloadA),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: Self.now,
            allowlist: { snapshot }
        )
        #expect(same.decision == .allow)
    }
}

import Foundation
import Testing
import RVDomain
import RVEngine
import RVPolicy
@testable import RVService

// B1 end to end: a grant planted for one invocation spelling spends for
// the identical re-issue and denies same-view wrapper/assignment/argv0
// variants — in both directions.

struct GatedEvaluateInvocationBindingTests {
    private static let plain = "git reset --hard"
    private static let sudo = "sudo git reset --hard"
    private static let env = "env LD_PRELOAD=/tmp/evil.so git reset --hard"
    private static let assigned = "GIT_DIR=.git git reset --hard"
    private static let pathed = "/bin/git reset --hard"
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func request(_ command: String) -> EvaluationRequest {
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs)
    }

    private static func plant(
        _ table: EphemeralAllowOnceTable,
        _ command: String,
        code: String
    ) async -> EphemeralAllowOnceTable.PlantResult {
        await table.plant(
            matchingView: Normalize.matchingView(of: command),
            cwd: wd("/tmp/ws"),
            codeHash: code,
            now: Self.now,
            maskedSegments: Normalize.maskedSegments(of: command),
            invocationPrefix: Normalize.invocationPrefix(of: command)
        )
    }

    private static func apply(
        _ gated: GatedEvaluate,
        _ command: String,
        grants: EphemeralAllowOnceTable
    ) async -> EvaluationResult {
        await gated.apply(
            Self.request(command),
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: Self.now,
            allowlist: { .empty }
        )
    }

    @Test func variantsShareViewButNotPrefix() {
        let view = Normalize.matchingView(of: Self.plain)
        for variant in [Self.sudo, Self.env, Self.assigned, Self.pathed] {
            #expect(
                Normalize.matchingView(of: variant) == view,
                "variant must share the view: \(variant)"
            )
            #expect(
                Normalize.invocationPrefix(of: variant) != Normalize.invocationPrefix(of: Self.plain),
                "variant must separate the prefix: \(variant)"
            )
        }
        #expect(Normalize.invocationPrefix(of: Self.plain) == [])
    }

    @Test func plainGrantDeniesWrappedRetries() async {
        for variant in [Self.sudo, Self.env, Self.assigned, Self.pathed] {
            let grants = EphemeralAllowOnceTable()
            let gated = GatedEvaluate()
            let baseline = await Self.apply(gated, variant, grants: grants)
            guard case .deny = baseline.decision else {
                Issue.record("variant must deny without a grant, got \(baseline.decision): \(variant)")
                return
            }
            #expect(await Self.plant(grants, Self.plain, code: "b1-e2e-plain-\(variant)") == .planted)
            let applied = await Self.apply(gated, variant, grants: grants)
            guard case .deny = applied.decision else {
                Issue.record("wrapped retry must deny, got \(applied.decision): \(variant)")
                return
            }
            // The rejected spend must not burn the grant.
            let same = await Self.apply(gated, Self.plain, grants: grants)
            #expect(same.decision == .allow, "plain re-issue must allow after \(variant) deny")
        }
    }

    @Test func wrappedGrantSpendsWrappedOnce() async {
        let grants = EphemeralAllowOnceTable()
        let gated = GatedEvaluate()
        #expect(await Self.plant(grants, Self.sudo, code: "b1-e2e-sudo") == .planted)
        let plain = await Self.apply(gated, Self.plain, grants: grants)
        guard case .deny = plain.decision else {
            Issue.record("plain retry of a wrapped grant must deny, got \(plain.decision)")
            return
        }
        let same = await Self.apply(gated, Self.sudo, grants: grants)
        #expect(same.decision == .allow)
        let again = await Self.apply(gated, Self.sudo, grants: grants)
        guard case .deny = again.decision else {
            Issue.record("second wrapped spend must deny, got \(again.decision)")
            return
        }
    }

    @Test func wrappedVariantsDoNotShare() async {
        let grants = EphemeralAllowOnceTable()
        let gated = GatedEvaluate()
        #expect(await Self.plant(grants, Self.sudo, code: "b1-e2e-cross") == .planted)
        let cross = await Self.apply(gated, Self.env, grants: grants)
        guard case .deny = cross.decision else {
            Issue.record("cross-variant spend must deny, got \(cross.decision)")
            return
        }
        let same = await Self.apply(gated, Self.sudo, grants: grants)
        #expect(same.decision == .allow)
    }
}

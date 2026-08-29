import Foundation
import Testing
import RVDomain
import RVTheme
@testable import RVCLI

@Suite("Explain Git semantics")
struct ExplainGitSemanticsTests {
    @Test func explain_checkoutCreate_identifiesBranchCreationAndAllows() async throws {
        let result = try await cliRun(
            kind: .explain,
            command: "git checkout -b feature",
            probe: prettyProbe(),
            requested: .automatic
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("Decision: ALLOW"))
        #expect(result.stdout.contains("branch creation"))
        #expect(result.stdout.contains("local branch create"))
        #expect(result.stdout.contains("feature"))
    }

    @Test func explain_checkoutDiscard_identifiesLocalOverwrite() async throws {
        let result = try await cliRun(
            kind: .explain,
            command: "git checkout -- file.swift",
            probe: prettyProbe(),
            requested: .automatic
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("Decision: DENY"))
        #expect(result.stdout.contains("working-tree overwrite/discard"))
        #expect(result.stdout.contains("file.swift"))
        #expect(result.stdout.contains("core.git/checkout-discard"))
    }

    @Test func explain_pushVersusForce_changesScopeAndImpact() async throws {
        let normal = try await cliRun(
            kind: .explain,
            command: "git push origin feature",
            probe: prettyProbe(),
            requested: .automatic
        )
        let forced = try await cliRun(
            kind: .explain,
            command: "git push --force origin main",
            probe: prettyProbe(),
            requested: .automatic
        )
        #expect(normal.stdout.contains("Decision: ALLOW"))
        #expect(normal.stdout.contains("Action       push"))
        #expect(normal.stdout.contains("Scope        remote"))
        #expect(forced.stdout.contains("Decision: DENY"))
        #expect(forced.stdout.contains("force-push"))
        #expect(forced.stdout.contains("remote shared-branch mutation"))
        #expect(forced.stdout.contains("main"))
        #expect(normal.stdout.contains("force-push") == false)
    }

    @Test func explain_unsupportedGlobals_fallBackInsteadOfAllowing() async throws {
        let result = try await cliRun(
            kind: .explain,
            command: "git --weird-flag reset --hard",
            probe: prettyProbe(),
            requested: .automatic
        )
        #expect(result.stdout.contains("Decision: DENY"))
        #expect(result.stdout.contains("core.git/reset-hard"))
        #expect(result.stdout.contains("Semantic") == false)
    }
}

private func prettyProbe() -> ThemeProbe {
    ThemeProbe(
        stdinIsTTY: true,
        stdoutIsTTY: true,
        jsonFlag: false,
        robotFlag: false,
        plainFlag: true,
        noColorFlag: false,
        ci: false,
        noColorEnv: false,
        termDumb: false
    )
}

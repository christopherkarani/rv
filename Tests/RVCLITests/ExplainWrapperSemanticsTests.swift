import Foundation
import Testing
import RVDomain
import RVTheme
@testable import RVCLI

@Suite("Explain wrapper semantics")
struct ExplainWrapperSemanticsTests {
    @Test func explain_bashDashC_matchesDirectGitAction() async throws {
        let direct = try await explain("git reset --hard")
        let wrapped = try await explain("bash -c 'git reset --hard'")
        #expect(direct.stdout.contains("Decision: DENY"))
        #expect(wrapped.stdout.contains("Decision: DENY"))
        #expect(direct.stdout.contains("reset --hard"))
        #expect(wrapped.stdout.contains("reset --hard"))
        #expect(wrapped.stdout.contains("Wrappers"))
        #expect(wrapped.stdout.contains("bash"))
    }

    @Test func explain_sudoEnvSh_showsWrappers() async throws {
        let result = try await explain("sudo env FOO=bar sh -c 'git reset --hard'")
        #expect(result.stdout.contains("Decision: DENY"))
        #expect(result.stdout.contains("reset --hard"))
        #expect(result.stdout.contains("sudo → env → sh") || result.stdout.contains("sudo"))
        #expect(result.stdout.contains("Wrappers"))
    }

    @Test func explain_echoQuotedRm_isNotDelete() async throws {
        let result = try await explain("echo 'rm -rf /'")
        #expect(result.stdout.contains("Decision: ALLOW"))
        #expect(result.stdout.contains("Action       delete") == false)
    }

    @Test func explain_deepWrappers_failClosed() async throws {
        let command = "sudo env command sudo env command sudo env command bash -c 'echo hello'"
        let result = try await explain(command)
        #expect(result.stdout.contains("Decision: DENY"))
        #expect(result.stdout.contains("unwrap limit exceeded"))
        #expect(result.stdout.contains("Decision: ALLOW") == false)
    }
}

private func explain(_ command: String) async throws -> CLIResult {
    await CommandRun.run(
        kind: .explain,
        command: command,
        probe: ThemeProbe(
            stdinIsTTY: true,
            stdoutIsTTY: true,
            jsonFlag: false,
            robotFlag: false,
            plainFlag: true,
            noColorFlag: false,
            ci: false,
            noColorEnv: false,
            termDumb: false
        ),
        requested: .automatic,
        cwd: "/tmp/ws",
        allowOnceDirectory: try isolatedAllowOnceDirectory(),
        home: try isolatedHome()
    )
}

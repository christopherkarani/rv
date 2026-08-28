import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

@Suite("GatedEvaluate wrapper semantics")
struct GatedEvaluateWrapperSemanticsTests {
    @Test func bashDashC_matchesDirectGitReset() async throws {
        let direct = try await peek("git reset --hard")
        let wrapped = try await peek("bash -c 'git reset --hard'")
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.gitAction == .reset(mode: .hard, target: nil))
        #expect(wrapped.analysis.wrappers == [.bash])
    }

    @Test func sudoEnvSh_showsWrappersAndInnerAction() async throws {
        let result = try await peek("sudo env FOO=bar sh -c 'git reset --hard'")
        guard case .deny(let deny) = result.decision else {
            Issue.record("wrapped reset --hard must deny")
            return
        }
        #expect(deny.ruleID.pack == .coreGit)
        #expect(result.analysis.wrappers == [.sudo, .env, .sh])
        #expect(result.analysis.gitAction == .reset(mode: .hard, target: nil))
    }

    @Test func echoQuotedRm_isNotExecutedDelete() async throws {
        let result = try await peek("echo 'rm -rf /'")
        #expect(result.decision == .allow)
        #expect(result.analysis.filesystemAction == nil)
        #expect(result.analysis.innermost == .unknown)
    }

    @Test func pythonOsSystem_isSurfacedOrDenied() async throws {
        let result = try await peek(#"python -c "os.system('git reset --hard')""#)
        guard case .deny = result.decision else {
            Issue.record("python os.system reset --hard must not silent-allow")
            return
        }
        #expect(result.analysis.gitAction == .reset(mode: .hard, target: nil))
        #expect(result.analysis.wrappers == [.python])
    }

    @Test func deepWrapperChain_asksOrDenies() async throws {
        let command = "sudo env command sudo env command sudo env command bash -c 'echo hello'"
        let result = try await peek(command)
        guard case .deny(let deny) = result.decision else {
            Issue.record("deep wrappers must not silent-allow, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(result.analysis.innermost == .unwrapLimited)
    }
}

private func peek(_ command: String) async throws -> EvaluationResult {
    let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
    return await GatedEvaluate().peek(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        cwd: WorkingDirectory(validating: "/tmp/ws"),
        store: store,
        now: Date(timeIntervalSince1970: 1_700_000_000),
        allowlist: { .empty }
    )
}

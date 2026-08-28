import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

@Suite("GatedEvaluate Git semantics")
struct GatedEvaluateGitSemanticsTests {
    @Test func checkoutCreate_allowsAndNamesBranchCreation() async throws {
        let result = try await peek("git checkout -b feature")
        #expect(result.decision == .allow)
        #expect(
            result.analysis
                == .git(.createBranch(name: "feature", startPoint: nil, force: false))
        )
    }

    @Test func checkoutDiscard_deniesWithPackRuleAndDiscardAnalysis() async throws {
        let result = try await peek("git checkout -- file.swift")
        guard case .deny(let deny) = result.decision else {
            Issue.record("checkout -- must deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:checkout-discard")
        guard case .git(.discardWorktree(let pathspecs, _)) = result.analysis else {
            Issue.record("expected discard analysis")
            return
        }
        #expect(pathspecs == ["file.swift"])
    }

    @Test func pushVersusForcePush_differAndForceStaysDenied() async throws {
        let normal = try await peek("git push origin feature")
        let forced = try await peek("git push --force origin main")
        #expect(normal.analysis != forced.analysis)
        #expect(normal.decision == .allow)
        guard case .deny(let deny) = forced.decision else {
            Issue.record("force-push must deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:push-force-long")
        guard case .git(.push(_, _, let force, _)) = forced.analysis else {
            Issue.record("expected push analysis")
            return
        }
        #expect(force == .force)
    }

    @Test func unsupportedGlobals_stillDenyResetHard() async throws {
        let result = try await peek("git --weird-flag reset --hard")
        #expect(result.analysis == .unknown)
        guard case .deny(let deny) = result.decision else {
            Issue.record("unsupported globals must not auto-allow reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
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

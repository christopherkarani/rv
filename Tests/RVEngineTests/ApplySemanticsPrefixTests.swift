import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplySemantics prefix wrappers")
struct ApplySemanticsPrefixTests {
    @Test func timeoutReset_matchesDirectDecision() throws {
        let direct = try runSemanticsDoor("git reset --hard")
        let wrapped = try runSemanticsDoor("timeout 1 git reset --hard")
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.timeout])
    }

    @Test func niceReset_matchesDirectDecision() throws {
        let direct = try runSemanticsDoor("git reset --hard")
        let wrapped = try runSemanticsDoor("nice git reset --hard")
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.nice])
    }

    @Test func miseExecReset_matchesDirectDecision() throws {
        let direct = try runSemanticsDoor("git reset --hard")
        let wrapped = try runSemanticsDoor("mise exec -c 'git reset --hard'")
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.mise])
    }

    @Test func sshForceWithLease_isDeniedBySemantics() throws {
        let command = "ssh h 'git push --force-with-lease origin main'"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = try runSemanticsDoor(
            command,
            gitProbe: { _ in .probed(GitAnalysisContext(currentBranch: "main")) }
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("ssh force-with-lease to main must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(composed.analysis.gitAction != nil)
        #expect(composed.analysis.wrappers == [.ssh])
    }

    @Test func sshReset_matchesDirectDecision() throws {
        let direct = try runSemanticsDoor("git reset --hard")
        let wrapped = try runSemanticsDoor("ssh example 'git reset --hard'")
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.ssh])
    }
}

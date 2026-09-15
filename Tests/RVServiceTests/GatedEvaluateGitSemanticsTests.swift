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

    @Test func forceWithLeaseOnMainWithoutRefspec_deniesRemoteSharedBranch() async throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/main\n")
        let result = try await peek("git push --force-with-lease", cwd: repo)
        guard case .deny(let deny) = result.decision else {
            Issue.record("force-with-lease on main must deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(
            result.analysis
                == .git(
                    .push(remote: nil, refspec: "main", force: .forceWithLease, delete: false)
                )
        )
    }

    @Test func forceWithLeaseWithoutGitdir_doesNotInventMain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-git-nongit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = try await peek("git push --force-with-lease", cwd: root)
        if case .deny(let deny) = result.decision {
            #expect(deny.ruleID != ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
            #expect(deny.ruleID != ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID)
        }
        guard case .git(.push(_, let refspec, let force, _)) = result.analysis else {
            Issue.record("expected push analysis, got \(result.analysis)")
            return
        }
        #expect(force == .forceWithLease)
        #expect(refspec == nil)
    }
}

private func peek(_ command: String) async throws -> EvaluationResult {
    try await peek(command, cwd: WorkingDirectory(validating: "/tmp/ws"))
}

private func peek(_ command: String, cwd: URL) async throws -> EvaluationResult {
    try await peek(command, cwd: WorkingDirectory(validating: cwd.path))
}

private func peek(_ command: String, cwd: WorkingDirectory?) async throws -> EvaluationResult {
    let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
    return await GatedEvaluate().peek(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        cwd: cwd,
        store: store,
        now: Date(timeIntervalSince1970: 1_700_000_000),
        allowlist: { .empty }
    )
}

private func makeGitRepo(head: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-git-eval-\(UUID().uuidString)", isDirectory: true)
    let git = root.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try head.write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    return root
}

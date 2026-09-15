import Foundation
import Testing
import RVDomain
import RVEngine
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

    @Test func forceWithLeaseNoRefspec_onMain_isRemoteSharedBranch() async throws {
        let repo = try makeGitRepo(head: .attached("main"))
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try await peek("git push --force-with-lease", cwd: repo.path)
        guard case .deny(let deny) = result.decision else {
            Issue.record(
                "implicit force-with-lease on main must deny, got \(result.decision)"
            )
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(result.boundReview == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        guard case .git(.push(_, let refspec, .forceWithLease, false)) = result.analysis else {
            Issue.record("expected implicit main refspec, got \(result.analysis)")
            return
        }
        #expect(refspec == "main")
    }

    @Test func forceWithLeaseNoRefspec_withoutGitDir_doesNotInventMainOrUnresolvedPath() async throws {
        let root = try makeEmptyGitWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = wd(root.path)
        let world = GitLiveProbe.world(
            unwrapped: .complete(
                UnwrappedCommand(
                    command: ShellCommand(rawValue: "git push --force-with-lease"),
                    workingDirectory: cwd
                )
            ),
            fallbackCwd: cwd
        )
        #expect(world != .unprobed)
        guard case .probed(let context) = world else {
            Issue.record("missing gitdir must still be probed")
            return
        }
        #expect(context.currentBranch == nil)
        #expect(context.isSharedBranch == false)

        let result = try await peek("git push --force-with-lease", cwd: root.path)
        guard case .git(.push(_, let refspec, .forceWithLease, false)) = result.analysis else {
            Issue.record("expected push analysis, got \(result.analysis)")
            return
        }
        #expect(refspec == nil)
        guard case .deny(let deny) = result.decision else {
            Issue.record(
                "probed-unknown implicit force-with-lease must fail-closed ask, got \(result.decision)"
            )
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteBranchAsk.ruleID)
        #expect(deny.ruleID != ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID)
        #expect(deny.ruleID != ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(result.boundReview == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
    }

    @Test func forceWithLeaseNoRefspec_detachedHEAD_isRemoteBranchAsk() async throws {
        let repo = try makeGitRepo(head: .detached)
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try await peek("git push --force-with-lease", cwd: repo.path)
        guard case .deny(let deny) = result.decision else {
            Issue.record(
                "implicit force-with-lease on detached HEAD must ask, got \(result.decision)"
            )
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteBranchAsk.ruleID)
        #expect(result.boundReview == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
    }

    @Test func forceWithLeaseNoRefspec_unwrappedCwdBeatsFallback() async throws {
        let main = try makeGitRepo(head: .attached("main"))
        let feature = try makeGitRepo(head: .attached("feature"))
        defer {
            try? FileManager.default.removeItem(at: main)
            try? FileManager.default.removeItem(at: feature)
        }
        let result = try await peek(
            "env -C \(main.path) git push --force-with-lease",
            cwd: feature.path
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("unwrapped main cwd must hard-deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(result.boundReview == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch))
    }
}

private enum GitSemanticsHEAD {
    case attached(String)
    case detached
}

private func peek(_ command: String, cwd: String = "/tmp/ws") async throws -> EvaluationResult {
    let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
    return await GatedEvaluate().peek(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        cwd: WorkingDirectory(validating: cwd),
        store: store,
        now: Date(timeIntervalSince1970: 1_700_000_000),
        allowlist: { .empty }
    )
}

private func makeEmptyGitWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-gated-git-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeGitRepo(head: GitSemanticsHEAD) throws -> URL {
    let root = try makeEmptyGitWorkspace()
    let git = root.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    switch head {
    case .attached(let name):
        try "ref: refs/heads/\(name)\n".write(
            to: git.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
    case .detached:
        try "0123456789abcdef0123456789abcdef01234567\n".write(
            to: git.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
    }
    return root
}

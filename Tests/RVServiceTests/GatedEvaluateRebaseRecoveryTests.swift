import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

@Suite("GatedEvaluate rebase recovery")
struct GatedEvaluateRebaseRecoveryTests {
    @Test func rebaseDirAllowsCheckoutDiscard() async throws {
        let repo = try tempRepo(rebase: .merge)
        let result = try await apply("git checkout -- file.swift", cwd: repo)
        #expect(result.decision == .allow)
        #expect(result.analysis.gitAction == .discardWorktree(pathspecs: ["file.swift"], source: nil))
    }

    @Test func missingRebaseDirKeepsCheckoutDenied() async throws {
        let repo = try tempRepo(rebase: .none)
        let result = try await apply("git checkout -- file.swift", cwd: repo)
        guard case .deny(let deny) = result.decision else {
            Issue.record("checkout -- without rebase dirs must deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:checkout-discard")
    }

    @Test func rebaseDirKeepsResetHardDenied() async throws {
        let repo = try tempRepo(rebase: .merge)
        let result = try await apply("git reset --hard", cwd: repo)
        guard case .deny(let deny) = result.decision else {
            Issue.record("reset --hard must stay deny during rebase")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func rebaseDirAllowsRestoreWorktree() async throws {
        let repo = try tempRepo(rebase: .apply)
        let result = try await apply("git restore .", cwd: repo)
        #expect(result.decision == .allow)
        #expect(
            result.analysis.gitAction
                == .restore(pathspecs: ["."], staged: false, worktree: true, source: nil)
        )
    }

    @Test func rebaseDirDoesNotTreatRestoreStagedAsWorktreeDiscard() async throws {
        let repo = try tempRepo(rebase: .merge)
        let result = try await apply("git restore --staged .", cwd: repo)
        #expect(
            result.analysis.gitAction
                == .restore(pathspecs: ["."], staged: true, worktree: false, source: nil)
        )
        #expect(result.decision == .allow)
    }

    @Test func compoundCheckoutThenResetHardStaysDeniedDuringRebase() async throws {
        let repo = try tempRepo(rebase: .merge)
        let result = try await apply("git checkout -- file.swift; git reset --hard", cwd: repo)
        guard case .deny = result.decision else {
            Issue.record("compound checkout + reset --hard must stay deny during rebase")
            return
        }
        #expect(result.analysis.gitAction == nil)
    }

    @Test func checkoutTheirsDuringRebaseIsRecovered() async throws {
        let repo = try tempRepo(rebase: .merge)
        let result = try await apply("git checkout --theirs -- file.swift", cwd: repo)
        #expect(result.decision == .allow)
        #expect(result.analysis.gitAction == .discardWorktree(pathspecs: ["file.swift"], source: nil))
    }

    @Test func quotedBashCheckoutDiscardIsRecoveredDuringRebase() async throws {
        let repo = try tempRepo(rebase: .merge)
        let result = try await apply("bash -c 'git checkout -- file.swift'", cwd: repo)
        #expect(result.decision == .allow)
        #expect(result.analysis.gitAction == .discardWorktree(pathspecs: ["file.swift"], source: nil))
    }

    @Test func unquotedBashCheckoutStaysDeniedDuringRebase() async throws {
        let repo = try tempRepo(rebase: .merge)
        let result = try await apply("bash -c git checkout -- file.swift", cwd: repo)
        guard case .deny = result.decision else {
            Issue.record("unwrap-limited checkout must stay deny during rebase")
            return
        }
        #expect(result.analysis.innermost == .unwrapLimited)
    }

    @Test func relativeGitdirFileAllowsCheckoutDiscard() async throws {
        let fm = FileManager.default
        let root = try isolatedRepoRoot()
        let gitdir = root.appendingPathComponent("gitdir", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try fm.createDirectory(
            at: gitdir.appendingPathComponent("rebase-merge", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        let gitFile = worktree.appendingPathComponent(".git")
        try "gitdir: ../gitdir\n".write(to: gitFile, atomically: true, encoding: .utf8)
        let result = try await apply("git checkout -- file.swift", cwd: worktree.path)
        #expect(result.decision == .allow)
    }

    @Test func worktreeGitdirFileAllowsCheckoutDiscard() async throws {
        let fm = FileManager.default
        let root = try isolatedRepoRoot()
        let gitdir = root.appendingPathComponent("gitdir", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try fm.createDirectory(
            at: gitdir.appendingPathComponent("rebase-merge", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        let gitFile = worktree.appendingPathComponent(".git")
        try "gitdir: \(gitdir.path)\n".write(to: gitFile, atomically: true, encoding: .utf8)
        let result = try await apply("git checkout -- file.swift", cwd: worktree.path)
        #expect(result.decision == .allow)
    }

    @Test func nilCwdDoesNotAllowCheckoutEvenIfAnotherRepoIsRebasing() async throws {
        _ = try tempRepo(rebase: .merge)
        let result = try await apply("git checkout -- file.swift", cwd: nil)
        guard case .deny(let deny) = result.decision else {
            Issue.record("nil cwd must not rebase-recover")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:checkout-discard")
    }
}

private enum RebaseMarker {
    case none
    case merge
    case apply
}

private func apply(_ command: String, cwd: String?) async throws -> EvaluationResult {
    let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
    let working = cwd.flatMap(WorkingDirectory.init(validating:))
    return await GatedEvaluate().apply(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        cwd: working,
        store: store,
        now: Date(timeIntervalSince1970: 1_700_000_000),
        allowlist: { .empty }
    )
}

private func tempRepo(rebase: RebaseMarker) throws -> String {
    let root = try isolatedRepoRoot()
    let git = root.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    switch rebase {
    case .none:
        break
    case .merge:
        try FileManager.default.createDirectory(
            at: git.appendingPathComponent("rebase-merge", isDirectory: true),
            withIntermediateDirectories: true
        )
    case .apply:
        try FileManager.default.createDirectory(
            at: git.appendingPathComponent("rebase-apply", isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    return root.path
}

private func isolatedRepoRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-rebase-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

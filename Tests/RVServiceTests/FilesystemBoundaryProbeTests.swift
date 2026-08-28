import Foundation
import Testing
import RVDomain
import RVPolicy
import RVEngine
@testable import RVService

@Suite("Filesystem repository boundary probe")
struct FilesystemBoundaryProbeTests {
    @Test func symlinkToTempAndSSHShapedPath_usesResolvedScope() async throws {
        let repo = try makeBoundaryRepo()
        let outside = repo.deletingLastPathComponent().appendingPathComponent("boundary-temp")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(
            to: outside.appendingPathComponent("file"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("temp-link").path,
            withDestinationPath: outside.path
        )

        let home = try isolatedHomeDirectory()
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let key = ssh.appendingPathComponent("id_ed25519")
        try "key".write(to: key, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("ssh-link").path,
            withDestinationPath: key.path
        )

        let temp = try await peek("rm temp-link/file", cwd: repo)
        guard case .deny(let tempDeny) = temp.decision else {
            Issue.record("temp symlink must deny, got \(temp.decision)")
            return
        }
        #expect(tempDeny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
        #expect(temp.analysis.filesystemAction?.primaryTarget?.scope == .outsideRepository)
        #expect(temp.analysis.filesystemAction?.primaryTarget?.followedSymlink == true)

        let protected = try await peek(
            "rm ssh-link",
            cwd: repo,
            home: HomeDirectory(validating: home.path)
        )
        guard case .deny(let sshDeny) = protected.decision else {
            Issue.record("ssh-shaped symlink must deny, got \(protected.decision)")
            return
        }
        #expect(sshDeny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        #expect(protected.analysis.filesystemAction?.primaryTarget?.scope == .protectedPath)
    }

    @Test func worktreeAndSubmodule_useCheckoutBoundary() async throws {
        let main = try makeBoundaryRepo(name: "boundary-main")
        let worktree = main.deletingLastPathComponent()
            .appendingPathComponent("boundary-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(main.appendingPathComponent(".git/worktrees/wt").path)\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "inside".write(
            to: worktree.appendingPathComponent("tracked.swift"),
            atomically: true,
            encoding: .utf8
        )

        let worktreeInside = try await peek("echo hi > tracked.swift", cwd: worktree)
        #expect(worktreeInside.decision == .allow)
        #expect(
            worktreeInside.analysis.filesystemAction?.resources.filesystemScope
                == .insideRepository
        )

        let worktreeOutside = try await peek("echo hi > ../main-file", cwd: worktree)
        guard case .deny(let worktreeDeny) = worktreeOutside.decision else {
            Issue.record(
                "write into main from worktree must be outside, got \(worktreeOutside.decision)"
            )
            return
        }
        #expect(worktreeDeny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
        #expect(worktreeOutside.analysis.filesystemAction?.primaryTarget?.scope == .outsideRepository)

        let sub = main.appendingPathComponent("vendor/mod", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "gitdir: ../../.git/modules/mod\n"
            .write(to: sub.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "sub".write(to: sub.appendingPathComponent("lib.swift"), atomically: true, encoding: .utf8)

        let subInside = try await peek("echo hi > lib.swift", cwd: sub)
        #expect(subInside.decision == .allow)
        #expect(
            subInside.analysis.filesystemAction?.resources.filesystemScope == .insideRepository
        )

        let subOutside = try await peek("echo hi > ../../Sources/Foo.swift", cwd: sub)
        guard case .deny(let subDeny) = subOutside.decision else {
            Issue.record(
                "write into parent from submodule must be outside, got \(subOutside.decision)"
            )
            return
        }
        #expect(subDeny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
        #expect(subOutside.analysis.filesystemAction?.primaryTarget?.scope == .outsideRepository)

        let probe = FilesystemLiveProbe.context(
            command: ShellCommand(rawValue: "echo hi > lib.swift"),
            cwd: WorkingDirectory(validating: sub.path),
            homeDirectory: nil
        )
        #expect(probe.repositoryRoot?.rawValue == resolveExistingDirectory(sub.path))
    }

    @Test func deletedAndMovedCwd_failClosed() async throws {
        let deleted = try makeBoundaryRepo(name: "boundary-deleted")
        let deletedPath = deleted.path
        try FileManager.default.removeItem(at: deleted)
        let deletedResult = try await peek("echo hi > file", cwd: deleted)
        guard case .deny(let deletedDeny) = deletedResult.decision else {
            Issue.record("deleted cwd must fail-closed, got \(deletedResult.decision)")
            return
        }
        #expect(deletedDeny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID)
        #expect(deletedResult.analysis.filesystemAction?.primaryTarget?.scope == .unknown)
        #expect(FilesystemLiveProbe.discoverRepositoryRoot(from: deletedPath) == nil)

        let moved = try makeBoundaryRepo(name: "boundary-moved")
        let stale = moved.path
        let dest = moved.deletingLastPathComponent()
            .appendingPathComponent("boundary-moved-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: moved, to: dest)
        let movedResult = try await peek(
            "echo hi > file",
            cwd: URL(fileURLWithPath: stale, isDirectory: true)
        )
        guard case .deny(let movedDeny) = movedResult.decision else {
            Issue.record("moved cwd must fail-closed, got \(movedResult.decision)")
            return
        }
        #expect(movedDeny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID)
        #expect(movedResult.analysis.filesystemAction?.primaryTarget?.scope != .insideRepository)
        #expect(FilesystemLiveProbe.discoverRepositoryRoot(from: stale) == nil)
        #expect(FilesystemLiveProbe.discoverRepositoryRoot(from: dest.path) != nil)
    }

    @Test func caseNormalization_followsPlatform() throws {
        let repo = try makeBoundaryRepo(name: "boundary-case")
        let file = repo.appendingPathComponent("CaseFile.swift")
        try "enum Case {}".write(to: file, atomically: true, encoding: .utf8)
        let folded = repo.appendingPathComponent("casefile.swift")
        let caseInsensitive = FileManager.default.fileExists(atPath: folded.path)
            && file.path != folded.path

        let fact = FilesystemLiveProbe.resolve(
            apparent: "casefile.swift",
            workingDirectory: repo.path,
            homeDirectory: nil
        )
        if caseInsensitive {
            #expect(
                fact.canonical == file.path
                    || fact.canonical.lowercased() == file.path.lowercased()
            )
            let context = FilesystemLiveProbe.context(
                command: ShellCommand(rawValue: "rm casefile.swift"),
                cwd: WorkingDirectory(validating: repo.path),
                homeDirectory: nil
            )
            let analysis = analyzeFilesystem(
                ShellCommand(rawValue: "rm casefile.swift"),
                context: context
            )
            #expect(analysis.filesystemAction?.primaryTarget?.scope == .insideRepository)
        } else {
            #expect(fact.canonical.hasSuffix("casefile.swift"))
            #expect(fact.canonical != file.path)
        }
    }
}

private func peek(
    _ command: String,
    cwd: URL,
    home: HomeDirectory? = nil
) async throws -> EvaluationResult {
    let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
    return await GatedEvaluate().peek(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        cwd: WorkingDirectory(validating: cwd.path),
        home: home,
        store: store,
        now: Date(timeIntervalSince1970: 1_700_000_000),
        allowlist: { .empty }
    )
}

private func makeBoundaryRepo(name: String = "boundary-repo") throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Sources", isDirectory: true),
        withIntermediateDirectories: true
    )
    try "enum Foo {}".write(
        to: root.appendingPathComponent("Sources/Foo.swift"),
        atomically: true,
        encoding: .utf8
    )
    return root
}

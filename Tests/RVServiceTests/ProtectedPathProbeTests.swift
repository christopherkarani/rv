import Foundation
import Testing
import RVDomain
import RVPolicy
import RVEngine
@testable import RVService

@Suite("Protected host path probe")
struct ProtectedPathProbeTests {
    @Test func homeAliases_allDenyAsProtectedPath() async throws {
        let repo = try makeProtectedRepo()
        let home = try isolatedHomeDirectory()
        try seedSSH(in: home)
        let homeDir = try #require(HomeDirectory(validating: home.path))

        let commands = [
            "echo leaked > ~/.ssh/config",
            "echo leaked > $HOME/.ssh/config",
            "echo leaked > ${HOME}/.ssh/config",
            "rm ~/.ssh/config",
        ]
        for command in commands {
            let result = try await peek(command, cwd: repo, home: homeDir)
            guard case .deny(let deny) = result.decision else {
                Issue.record("\(command) must deny, got \(result.decision)")
                continue
            }
            // Echo redirects can hit core.filesystem first (pack-deny floor).
            // Classification must still be protectedPath.
            #expect(
                deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID
                    || deny.ruleID.pack == .coreSecrets
                    || deny.ruleID.pack == .coreFilesystem
            )
            #expect(result.analysis.filesystemAction?.primaryTarget?.scope == .protectedPath)
            #expect(result.analysis.filesystemAction?.explainCategory == "ssh")
        }
    }

    @Test func relativeAliasFromNestedCwd_isProtected() async throws {
        let repo = try makeProtectedRepo()
        let home = try isolatedHomeDirectory()
        try seedSSH(in: home)
        let nested = repo.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let relative = relativePath(from: nested, to: home.appendingPathComponent(".ssh/config"))
        let result = try await peek(
            "rm \(relative)",
            cwd: nested,
            home: HomeDirectory(validating: home.path)
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("relative home alias must deny, got \(result.decision)")
            return
        }
        #expect(
            deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID
                || deny.ruleID.pack == .coreSecrets
        )
        #expect(result.analysis.filesystemAction?.primaryTarget?.scope == .protectedPath)
    }

    @Test func inRepoSymlinkToSSH_isProtectedNotInRepo() async throws {
        let repo = try makeProtectedRepo()
        let home = try isolatedHomeDirectory()
        try seedSSH(in: home)
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("ssh-link").path,
            withDestinationPath: home.appendingPathComponent(".ssh/config").path
        )
        let result = try await peek(
            "rm ssh-link",
            cwd: repo,
            home: HomeDirectory(validating: home.path)
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("symlink into ~/.ssh must deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        #expect(result.analysis.filesystemAction?.primaryTarget?.scope == .protectedPath)
        #expect(result.analysis.filesystemAction?.primaryTarget?.followedSymlink == true)
        #expect(result.analysis.filesystemAction?.explainCatalogRule == "core.secrets/home-ssh")
    }

    @Test func allowlistCannotWhitelistProtectedSSH() async throws {
        let repo = try makeProtectedRepo()
        let home = try isolatedHomeDirectory()
        try seedSSH(in: home)
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("ssh-link").path,
            withDestinationPath: home.appendingPathComponent(".ssh/config").path
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(
                selector: .exactCommand("rm ssh-link"),
                reason: "repo overlay",
                addedAt: now
            ),
            AllowlistEntry(
                selector: .rule(ActionPolicyEngine.Builtin.protectedPath.ruleID),
                reason: "repo overlay rule",
                addedAt: now
            ),
        ])
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let result = await GatedEvaluate().peek(
            EvaluationRequest(
                command: ShellCommand(rawValue: "rm ssh-link"),
                enabledPacks: dayOnePackIDs
            ),
            cwd: WorkingDirectory(validating: repo.path),
            home: HomeDirectory(validating: home.path),
            store: store,
            now: now,
            allowlist: { allowlist }
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("allowlist must not lift protected path, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
    }

    @Test func siblingRepository_isOutsideAndNotWhitelisted() async throws {
        let repo = try makeProtectedRepo()
        let sibling = repo.deletingLastPathComponent()
            .appendingPathComponent("sibling-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sibling.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "secret".write(
            to: sibling.appendingPathComponent("tracked.swift"),
            atomically: true,
            encoding: .utf8
        )
        let relative = relativePath(
            from: repo,
            to: sibling.appendingPathComponent("tracked.swift")
        )
        let denied = try await peek("echo leaked > \(relative)", cwd: repo)
        guard case .deny(let deny) = denied.decision else {
            Issue.record("sibling repo write must deny, got \(denied.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(
                selector: .exactCommand(denied.matchingView),
                reason: "repo overlay",
                addedAt: now
            ),
            AllowlistEntry(
                selector: .rule(ActionPolicyEngine.Builtin.outsideRepository.ruleID),
                reason: "repo overlay rule",
                addedAt: now
            ),
        ])
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let lifted = await GatedEvaluate().peek(
            EvaluationRequest(
                command: ShellCommand(rawValue: "echo leaked > \(relative)"),
                enabledPacks: dayOnePackIDs
            ),
            cwd: WorkingDirectory(validating: repo.path),
            store: store,
            now: now,
            allowlist: { allowlist }
        )
        guard case .deny(let kept) = lifted.decision else {
            Issue.record("allowlist must not lift sibling-repo write")
            return
        }
        #expect(kept.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
    }

    @Test func ordinaryInRepoFile_isUnaffected() async throws {
        let repo = try makeProtectedRepo()
        let result = try await peek("echo hi > Sources/Foo.swift", cwd: repo)
        #expect(result.decision == .allow)
        #expect(result.analysis.filesystemAction?.primaryTarget?.scope == .insideRepository)
        #expect(result.analysis.filesystemAction?.primaryTarget?.protectedMatch == nil)
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

private func makeProtectedRepo() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-protected-\(UUID().uuidString)", isDirectory: true)
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

private func seedSSH(in home: URL) throws {
    let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
    try "host *".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
}

private func relativePath(from origin: URL, to target: URL) -> String {
    var originParts = origin.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let targetParts = target.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    while originParts.isEmpty == false,
        targetParts.starts(with: originParts) == false
    {
        originParts.removeLast()
    }
    let ups = origin.path.split(separator: "/", omittingEmptySubsequences: true).count - originParts.count
    let down = targetParts.dropFirst(originParts.count)
    return Array(repeating: "..", count: ups).joined(separator: "/")
        + (down.isEmpty ? "" : "/" + down.joined(separator: "/"))
}

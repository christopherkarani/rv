import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

@Suite("GatedEvaluate filesystem semantics")
struct GatedEvaluateFilesystemSemanticsTests {
    @Test func generatedAndSourceDeletes_differ() async throws {
        let repo = try makeFilesystemRepo()
        let generated = try await peek("rm .build/artifact", cwd: repo)
        let source = try await peek("rm Sources/Foo.swift", cwd: repo)
        guard case .filesystem(let generatedAction) = generated.analysis else {
            Issue.record("expected generated filesystem analysis")
            return
        }
        guard case .filesystem(let sourceAction) = source.analysis else {
            Issue.record("expected source filesystem analysis")
            return
        }
        #expect(generatedAction.resources.resourceKind == .generatedOutput)
        #expect(sourceAction.resources.resourceKind == .sourceCode)
        #expect(generatedAction.resources.filesystemScope == .insideRepository)
        #expect(sourceAction.resources.filesystemScope == .insideRepository)
        #expect(generated.analysis != source.analysis)
    }

    @Test func parentTraversal_isOutsideRepository() async throws {
        let repo = try makeFilesystemRepo()
        let result = try await peek("rm ../outside-file", cwd: repo)
        guard case .filesystem(let action) = result.analysis else {
            Issue.record("expected filesystem analysis")
            return
        }
        #expect(action.primaryTarget?.scope == .outsideRepository)
        #expect(action.primaryTarget?.canonical.hasSuffix("/outside-file") == true)
    }

    @Test func symlinkEscape_usesResolvedTarget() async throws {
        let repo = try makeFilesystemRepo()
        let outside = repo.deletingLastPathComponent().appendingPathComponent("outside-target")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        let link = repo.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: outside.path
        )
        let result = try await peek("rm escape-link", cwd: repo)
        guard case .filesystem(let action) = result.analysis else {
            Issue.record("expected filesystem analysis, got \(result.analysis)")
            return
        }
        #expect(action.primaryTarget?.followedSymlink == true)
        #expect(action.primaryTarget?.scope == .outsideRepository)
        #expect(action.primaryTarget?.canonical == outside.path)
    }

    @Test func symlinkToProtected_isNonOverridableDeny() async throws {
        let repo = try makeFilesystemRepo()
        let home = try isolatedHomeDirectory()
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let key = ssh.appendingPathComponent("id_rsa")
        try "key".write(to: key, atomically: true, encoding: .utf8)
        let link = repo.appendingPathComponent("ssh-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: key.path
        )
        let result = try await peek(
            "rm ssh-link",
            cwd: repo,
            home: HomeDirectory(validating: home.path)
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("protected symlink must deny")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID)
        guard case .filesystem(let action) = result.analysis else {
            Issue.record("expected filesystem analysis")
            return
        }
        #expect(action.primaryTarget?.scope == .protectedPath)
        #expect(action.primaryTarget?.followedSymlink == true)
    }

    @Test func bashDashC_deniesRmRfWithFilesystemAnalysis() async throws {
        let repo = try makeFilesystemRepo()
        let result = try await peek("bash -c 'rm -rf /'", cwd: repo)
        guard case .deny(let deny) = result.decision else {
            Issue.record("wrapper must not auto-allow rm -rf")
            return
        }
        #expect(deny.ruleID.pack == .coreFilesystem)
        #expect(result.analysis.wrappers == [.bash])
        #expect(result.analysis.filesystemAction != nil)
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

private func makeFilesystemRepo() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-fs-repo-\(UUID().uuidString)", isDirectory: true)
    let build = root.appendingPathComponent(".build", isDirectory: true)
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    try "artifact".write(
        to: build.appendingPathComponent("artifact"),
        atomically: true,
        encoding: .utf8
    )
    try "enum Foo {}".write(
        to: sources.appendingPathComponent("Foo.swift"),
        atomically: true,
        encoding: .utf8
    )
    return root
}

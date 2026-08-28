import Foundation
import Testing
import RVDomain
import RVTheme
@testable import RVCLI

@Suite("Explain filesystem semantics")
struct ExplainFilesystemSemanticsTests {
    @Test func explain_generatedBuild_marksInsideRepoGenerated() async throws {
        let repo = try makeExplainRepo()
        let result = try await explain("rm .build/artifact", cwd: repo)
        #expect(result.stdout.contains("Decision: ALLOW"))
        #expect(result.stdout.contains("inside repo"))
        #expect(result.stdout.contains("generated output"))
        #expect(result.stdout.contains("source code") == false)
    }

    @Test func explain_sourceFile_marksSourceCode() async throws {
        let repo = try makeExplainRepo()
        let result = try await explain("rm Sources/Foo.swift", cwd: repo)
        #expect(result.stdout.contains("Decision: ALLOW"))
        #expect(result.stdout.contains("inside repo"))
        #expect(result.stdout.contains("source code"))
        #expect(result.stdout.contains("generated output") == false)
    }

    @Test func explain_parentTraversal_isOutsideRepo() async throws {
        let repo = try makeExplainRepo()
        let result = try await explain("rm ../outside-file", cwd: repo)
        #expect(result.stdout.contains("outside repo"))
        #expect(result.stdout.contains("Action       delete"))
    }

    @Test func explain_symlinkEscape_usesResolvedTarget() async throws {
        let repo = try makeExplainRepo()
        let outside = repo.deletingLastPathComponent().appendingPathComponent("outside-target")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("escape-link").path,
            withDestinationPath: outside.path
        )
        let result = try await explain("rm escape-link", cwd: repo)
        #expect(result.stdout.contains("outside repo"))
        #expect(result.stdout.contains(outside.path))
        #expect(result.stdout.contains("inside repo") == false)
    }

    @Test func explain_unsupportedWrapper_fallsBackInsteadOfAllowing() async throws {
        let repo = try makeExplainRepo()
        let result = try await explain("bash -c 'rm -rf /'", cwd: repo)
        #expect(result.stdout.contains("Decision: DENY"))
        #expect(result.stdout.contains("core.filesystem"))
        #expect(result.stdout.contains("Semantic") == false)
    }
}

private func explain(_ command: String, cwd: URL) async throws -> CLIResult {
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
        cwd: cwd.path,
        allowOnceDirectory: try isolatedAllowOnceDirectory(),
        home: try isolatedHome()
    )
}

private func makeExplainRepo() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-fs-explain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".build", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Sources", isDirectory: true),
        withIntermediateDirectories: true
    )
    try "artifact".write(
        to: root.appendingPathComponent(".build/artifact"),
        atomically: true,
        encoding: .utf8
    )
    try "enum Foo {}".write(
        to: root.appendingPathComponent("Sources/Foo.swift"),
        atomically: true,
        encoding: .utf8
    )
    return root
}

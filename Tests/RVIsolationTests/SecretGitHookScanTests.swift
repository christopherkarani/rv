import Foundation
import Testing

@testable import RVIsolation

@Suite struct SecretGitHookScanTests {
    private func makeRepo() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-hook-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "init", "-q"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return directory
    }

    private func git(_ work: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", work.path] + args
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func gitEnvironmentForwardsTheIndexAndObjectStoreAsAbsolutePaths() {
        let forwarded = SecretGitHook.gitEnvironment(inheriting: [
            "PATH": "/bin", "GIT_INDEX_FILE": ".git/index.lock", "GIT_DIR": "/abs/.git",
            "GIT_OBJECT_DIRECTORY": "/abs/objects", "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/abs/alt",
            "GIT_SSH_COMMAND": "evil",
        ])
        #expect(forwarded["GIT_INDEX_FILE"] == FileManager.default.currentDirectoryPath + "/.git/index.lock")
        #expect(forwarded["GIT_DIR"] == "/abs/.git")
        #expect(forwarded["GIT_OBJECT_DIRECTORY"] == "/abs/objects")
        #expect(forwarded["GIT_ALTERNATE_OBJECT_DIRECTORIES"] == "/abs/alt")
        #expect(forwarded["GIT_SSH_COMMAND"] == nil)
        #expect(forwarded["HOME"] == "/tmp")
    }

    @Test func stagedListingFailsClosedWhenItHitsItsCap() throws {
        let work = try makeRepo()
        defer { try? FileManager.default.removeItem(at: work) }
        for name in ["a.txt", "b.txt", "c.txt"] { try Data("x\n".utf8).write(to: work.appendingPathComponent(name)) }
        try git(work, ["add", "."])
        let git = try #require(SecretCommandProviders.executable("git", environment: ProcessInfo.processInfo.environment))
        let environment = SecretGitHook.gitEnvironment(inheriting: ProcessInfo.processInfo.environment)
        #expect(try SecretGitHook.staged(git: git, workTree: work, environment: environment).get().count == 3)
        let capped = SecretGitHook.staged(git: git, workTree: work, environment: environment, listingLimit: 64)
        #expect(capped == .failure(SecretGitHookError("too many staged files to list")))
    }
}

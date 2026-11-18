#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVIsolation

/// One temp tree per test: `host/` (owner files), `workspace/` (the live
/// workspace volume stand-in), `outside/` (a host path neither side may
/// reach) and `home/.config/rv` (rv's config dir).
private struct TransferFixture {
    let root: String
    var host: String { root + "/host" }
    var workspace: String { root + "/workspace" }
    var outside: String { root + "/outside" }
    var configDir: String { root + "/home/.config/rv" }

    init() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        root = base + "/rv-transfer-\(UUID().uuidString)"
        for directory in [host, workspace, outside, configDir] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    func upload(
        _ source: String, to destination: String? = nil, gitignore: Bool = true,
        limits: WorkspaceTransferLimits = .standard
    ) -> Result<WorkspaceTransferSummary, WorkspaceTransferRefusal> {
        WorkspaceTransfer.upload(WorkspaceUploadRequest(
            source: source, workspace: workspace, destination: destination,
            protectedRoots: [configDir], gitignore: gitignore, limits: limits
        ))
    }

    func download(
        _ source: String, to destination: String, gitignore: Bool = true,
        limits: WorkspaceTransferLimits = .standard
    ) -> Result<WorkspaceTransferSummary, WorkspaceTransferRefusal> {
        WorkspaceTransfer.download(WorkspaceDownloadRequest(
            workspace: workspace, source: source, destination: destination,
            protectedRoots: [configDir], gitignore: gitignore, limits: limits
        ))
    }
}

private func refusal<T>(_ result: Result<T, WorkspaceTransferRefusal>) -> WorkspaceTransferRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

@Suite("Workspace upload")
struct WorkspaceUploadTests {
    @Test func copiesATreeIntoTheWorkspaceHonouringGitignore() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/data/.gitignore", "*.log\nbuild/\n")
        try fixture.write(fixture.host + "/data/a.txt", "a")
        try fixture.write(fixture.host + "/data/sub/b.txt", "bb")
        try fixture.write(fixture.host + "/data/run.log", "log")
        try fixture.write(fixture.host + "/data/build/out.o", "o")
        try fixture.write(fixture.host + "/data/.git/config", "[core]")

        let summary = try fixture.upload(fixture.host + "/data", to: "inputs/data").get()

        #expect(fixture.read(fixture.workspace + "/inputs/data/a.txt") == "a")
        #expect(fixture.read(fixture.workspace + "/inputs/data/sub/b.txt") == "bb")
        #expect(fixture.exists(fixture.workspace + "/inputs/data/.gitignore"))
        #expect(fixture.exists(fixture.workspace + "/inputs/data/run.log") == false)
        #expect(fixture.exists(fixture.workspace + "/inputs/data/build") == false)
        #expect(fixture.exists(fixture.workspace + "/inputs/data/.git") == false)
        #expect(summary.files == 3)
        #expect(summary.bytes == 1 + 2 + UInt64("*.log\nbuild/\n".utf8.count))
        #expect(summary.ignored == 3)
    }

    @Test func noGitignoreCopiesEverything() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/data/.gitignore", "*.log\n")
        try fixture.write(fixture.host + "/data/run.log", "log")
        _ = try fixture.upload(fixture.host + "/data", gitignore: false).get()
        #expect(fixture.read(fixture.workspace + "/data/run.log") == "log")
    }

    @Test func aSingleFileDefaultsToItsNameAtTheWorkspaceRoot() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/notes.md", "hi")
        _ = try fixture.upload(fixture.host + "/notes.md").get()
        #expect(fixture.read(fixture.workspace + "/notes.md") == "hi")
    }

    @Test func refusesParentReferencesInEitherPath() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/f", "x")
        #expect(refusal(fixture.upload(fixture.host + "/../host/f")) == .unsafePath(fixture.host + "/../host/f"))
        #expect(refusal(fixture.upload(fixture.host + "/f", to: "a/../../escape")) == .unsafePath("a/../../escape"))
        #expect(refusal(fixture.upload(fixture.host + "/f", to: "/etc/f")) == .unsafePath("/etc/f"))
        #expect(refusal(fixture.upload("relative/f")) == .unsafePath("relative/f"))
        #expect(fixture.exists(fixture.root + "/escape") == false)
    }

    @Test func refusesASymlinkSourceAndASymlinkInsideTheTree() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.outside + "/secret", "s")
        try fixture.write(fixture.host + "/data/ok.txt", "ok")
        #expect(symlink(fixture.outside + "/secret", fixture.host + "/data/link") == 0)
        #expect(symlink(fixture.outside, fixture.host + "/top-link") == 0)

        #expect(refusal(fixture.upload(fixture.host + "/top-link")) == .symlink(fixture.host + "/top-link"))
        #expect(refusal(fixture.upload(fixture.host + "/data")) == .symlink("data/link"))
        // Refused during planning: nothing reached the workspace.
        #expect(fixture.exists(fixture.workspace + "/data") == false)
    }

    @Test func refusesRvConfigDirInsideOrContaining() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.configDir + "/secrets.json", "{}")
        #expect(refusal(fixture.upload(fixture.configDir + "/secrets.json")) == .protectedSource(fixture.configDir + "/secrets.json"))
        #expect(refusal(fixture.upload(fixture.configDir)) == .protectedSource(fixture.configDir))
        #expect(refusal(fixture.upload(fixture.root + "/home")) == .protectedSource(fixture.root + "/home"))
        #expect(fixture.exists(fixture.workspace + "/home") == false)
    }

    @Test func refusesASourceThatOverlapsTheWorkspace() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/inside.txt", "w")
        #expect(refusal(fixture.upload(fixture.workspace + "/inside.txt", to: "copy.txt")) == .protectedSource(fixture.workspace + "/inside.txt"))
        #expect(refusal(fixture.upload(fixture.root, to: "everything")) == .protectedSource(fixture.root))
    }

    @Test func refusesAHardLinkedSourceFile() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/data/plain", "p")
        #expect(link(fixture.host + "/data/plain", fixture.host + "/data/alias") == 0)
        #expect(refusal(fixture.upload(fixture.host + "/data")) == .hardLinked("data/alias") ||
            refusal(fixture.upload(fixture.host + "/data")) == .hardLinked("data/plain"))
    }

    @Test func refusesWorkspaceControlAndRunLaterDestinations() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/hook", "#!/bin/sh")
        for destination in [
            ".git/hooks/pre-commit", ".git/config", ".rv/policy.toml", ".config/rv/x", ".envrc",
            ".MCP.json", ".claude/settings.json", ".Claude/Hooks/x.sh", ".git/info/attributes",
        ] {
            #expect(refusal(fixture.upload(fixture.host + "/hook", to: destination)) == .protectedDestination(destination))
        }
        try fixture.write(fixture.host + "/tree/.envrc", "export X=1")
        #expect(refusal(fixture.upload(fixture.host + "/tree", to: ".", gitignore: false)) == .protectedDestination(".envrc"))
        #expect(fixture.exists(fixture.workspace + "/.envrc") == false)
    }

    @Test func refusesADestinationThroughAWorkspaceSymlink() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/f", "x")
        #expect(symlink(fixture.outside, fixture.workspace + "/link") == 0)
        #expect(refusal(fixture.upload(fixture.host + "/f", to: "link/f")) == .symlink("link"))
        #expect(fixture.exists(fixture.outside + "/f") == false)
    }

    @Test func replacesAnExistingWorkspaceNameWithoutFollowingIt() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/f", "new")
        try fixture.write(fixture.outside + "/target", "untouched")
        #expect(symlink(fixture.outside + "/target", fixture.workspace + "/f") == 0)
        _ = try fixture.upload(fixture.host + "/f").get()
        #expect(fixture.read(fixture.workspace + "/f") == "new")
        #expect(fixture.read(fixture.outside + "/target") == "untouched")
        try fixture.write(fixture.host + "/f", "newer")
        _ = try fixture.upload(fixture.host + "/f").get()
        #expect(fixture.read(fixture.workspace + "/f") == "newer")
    }

    @Test func enforcesCountAndSizeCaps() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/data/a", "12345")
        try fixture.write(fixture.host + "/data/b", "12345")
        var limits = WorkspaceTransferLimits.standard
        limits.maxBytes = 9
        #expect(refusal(fixture.upload(fixture.host + "/data", limits: limits)) == .tooLarge(9))
        limits = .standard
        limits.maxEntries = 2
        #expect(refusal(fixture.upload(fixture.host + "/data", limits: limits)) == .tooManyEntries(2))
        #expect(fixture.exists(fixture.workspace + "/data") == false)
    }
}

@Suite("Workspace download")
struct WorkspaceDownloadTests {
    @Test func copiesAWorkspaceTreeToANewHostPath() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/out/.gitignore", "*.tmp\n")
        try fixture.write(fixture.workspace + "/out/report.txt", "r")
        try fixture.write(fixture.workspace + "/out/scratch.tmp", "t")
        try fixture.write(fixture.workspace + "/out/deep/x.bin", "xx")

        let summary = try fixture.download("out", to: fixture.host + "/results").get()

        #expect(fixture.read(fixture.host + "/results/report.txt") == "r")
        #expect(fixture.read(fixture.host + "/results/deep/x.bin") == "xx")
        #expect(fixture.exists(fixture.host + "/results/scratch.tmp") == false)
        #expect(summary.files == 3)
        #expect(summary.ignored == 1)
    }

    @Test func aSingleFileDownloads() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/report.txt", "r")
        _ = try fixture.download("report.txt", to: fixture.host + "/report.txt").get()
        #expect(fixture.read(fixture.host + "/report.txt") == "r")
    }

    @Test func refusesUnsafeSourcePaths() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        #expect(refusal(fixture.download("../outside", to: fixture.host + "/x")) == .unsafePath("../outside"))
        #expect(refusal(fixture.download("/etc/passwd", to: fixture.host + "/x")) == .unsafePath("/etc/passwd"))
        #expect(fixture.exists(fixture.host + "/x") == false)
    }

    @Test func refusesAWorkspaceSymlinkAndLeavesNoDestination() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.outside + "/secret", "s")
        try fixture.write(fixture.workspace + "/out/ok.txt", "ok")
        #expect(symlink(fixture.outside + "/secret", fixture.workspace + "/out/z-link") == 0)
        #expect(symlink(fixture.outside, fixture.workspace + "/top-link") == 0)
        #expect(refusal(fixture.download("out", to: fixture.host + "/results")) == .symlink("out/z-link"))
        #expect(refusal(fixture.download("top-link", to: fixture.host + "/results")) == .symlink("top-link"))
        #expect(refusal(fixture.download("top-link/secret", to: fixture.host + "/results")) == .symlink("top-link"))
        #expect(fixture.exists(fixture.host + "/results") == false)
    }

    @Test func refusesSpecialFiles() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(atPath: fixture.workspace + "/out", withIntermediateDirectories: true)
        #expect(mkfifo(fixture.workspace + "/out/pipe", 0o600) == 0)
        #expect(refusal(fixture.download("out", to: fixture.host + "/results")) == .specialFile("out/pipe"))
        #expect(fixture.exists(fixture.host + "/results") == false)
    }

    @Test func refusesUnsafeGuestNames() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/out/evil\nname", "x")
        #expect(refusal(fixture.download("out", to: fixture.host + "/results")) == .unsafeName("out/evil\\x0aname"))
    }

    @Test func refusesAnExistingOrSymlinkedDestination() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/f", "agent")
        try fixture.write(fixture.host + "/existing", "mine")
        #expect(refusal(fixture.download("f", to: fixture.host + "/existing")) == .destinationExists(fixture.host + "/existing"))
        #expect(fixture.read(fixture.host + "/existing") == "mine")
        #expect(symlink(fixture.outside + "/planted", fixture.host + "/dangling") == 0)
        #expect(refusal(fixture.download("f", to: fixture.host + "/dangling")) == .destinationExists(fixture.host + "/dangling"))
        #expect(fixture.exists(fixture.outside + "/planted") == false)
    }

    @Test func refusesProtectedAndTraversingDestinations() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/f", "agent")
        #expect(refusal(fixture.download("f", to: fixture.configDir + "/policy.json")) == .protectedDestination(fixture.configDir + "/policy.json"))
        #expect(refusal(fixture.download("f", to: fixture.workspace + "/copy")) == .protectedDestination(fixture.workspace + "/copy"))
        #expect(refusal(fixture.download("f", to: fixture.host + "/../outside/f")) == .unsafePath(fixture.host + "/../outside/f"))
        #expect(refusal(fixture.download("f", to: "relative")) == .unsafePath("relative"))
        #expect(fixture.exists(fixture.configDir + "/policy.json") == false)
    }

    @Test func enforcesCapsAndLeavesNoPartialDestination() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/out/a", "12345")
        try fixture.write(fixture.workspace + "/out/b", "12345")
        var limits = WorkspaceTransferLimits.standard
        limits.maxBytes = 9
        #expect(refusal(fixture.download("out", to: fixture.host + "/results", limits: limits)) == .tooLarge(9))
        limits = .standard
        limits.maxEntries = 2
        #expect(refusal(fixture.download("out", to: fixture.host + "/results", limits: limits)) == .tooManyEntries(2))
        limits = .standard
        limits.maxDepth = 1
        #expect(refusal(fixture.download("out", to: fixture.host + "/results", limits: limits)) == nil)
        #expect(refusal(fixture.download("out", to: fixture.host + "/results2", limits: WorkspaceTransferLimits(maxEntries: 10, maxBytes: 100, maxDepth: 0))) == .tooDeep(0))
        #expect(fixture.exists(fixture.host + "/results2") == false)
    }

    @Test func refusesAnEmptySelection() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/out/.gitignore", "*\n")
        #expect(refusal(fixture.download("out", to: fixture.host + "/results")) == .nothingSelected)
    }

    @Test func dropsSetIDBitsAndKeepsOwnerExecute() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/tool", "#!/bin/sh")
        #expect(chmod(fixture.workspace + "/tool", 0o4755) == 0)
        _ = try fixture.download("tool", to: fixture.host + "/tool").get()
        var info = stat()
        #expect(stat(fixture.host + "/tool", &info) == 0)
        #expect(info.st_mode & 0o7000 == 0)
        #expect(info.st_mode & 0o100 != 0)
    }
}

@Suite("Workspace transfer paths")
struct WorkspaceTransferPathTests {
    @Test func workspaceRelativePathsRejectTraversalAndAbsolutes() {
        #expect(WorkspaceTransfer.workspaceComponents("a/b/c") == .success(["a", "b", "c"]))
        #expect(WorkspaceTransfer.workspaceComponents("./a//b/") == .success(["a", "b"]))
        #expect(WorkspaceTransfer.workspaceComponents(".") == .success([]))
        #expect(WorkspaceTransfer.workspaceComponents("a/../b") == .failure(.unsafePath("a/../b")))
        #expect(WorkspaceTransfer.workspaceComponents("/a") == .failure(.unsafePath("/a")))
        #expect(WorkspaceTransfer.workspaceComponents("") == .failure(.unsafePath("")))
        #expect(WorkspaceTransfer.workspaceComponents("a\u{1}b") == .failure(.unsafePath("a\\x01b")))
    }

    @Test func protectedWorkspacePathsFoldCase() {
        #expect(WorkspaceTransfer.isProtectedWorkspacePath([".GIT", "hooks", "x"]))
        #expect(WorkspaceTransfer.isProtectedWorkspacePath([".mcp.j\u{017F}on"]))
        #expect(WorkspaceTransfer.isProtectedWorkspacePath([".vscode", "tasks.json"]))
        #expect(WorkspaceTransfer.isProtectedWorkspacePath([".vscode", "launch.json"]) == false)
        #expect(WorkspaceTransfer.isProtectedWorkspacePath(["src", ".envrc"]) == false)
        #expect(WorkspaceTransfer.isProtectedWorkspacePath(["src", "main.swift"]) == false)
    }
}

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
        limits: WorkspaceTransferLimits = .standard, afterPlan: (@Sendable () -> Void)? = nil
    ) -> Result<WorkspaceTransferSummary, WorkspaceTransferRefusal> {
        var request = WorkspaceUploadRequest(
            source: source, workspace: workspace, destination: destination,
            protectedRoots: [configDir], gitignore: gitignore, limits: limits
        )
        request.afterPlan = afterPlan
        return WorkspaceTransfer.upload(request)
    }

    func download(
        _ source: String, to destination: String, gitignore: Bool = true,
        limits: WorkspaceTransferLimits = .standard, afterPlan: (@Sendable () -> Void)? = nil
    ) -> Result<WorkspaceTransferSummary, WorkspaceTransferRefusal> {
        var request = WorkspaceDownloadRequest(
            workspace: workspace, source: source, destination: destination,
            protectedRoots: [configDir], gitignore: gitignore, limits: limits
        )
        request.afterPlan = afterPlan
        return WorkspaceTransfer.download(request)
    }
}

private func isChanged<T>(_ result: Result<T, WorkspaceTransferRefusal>) -> Bool {
    if case .failure(.changed) = result { return true }
    return false
}

/// Swaps `directory` for a symlink to `target`, keeping the original aside.
private func swapForSymlink(_ directory: String, to target: String) {
    _ = rename(directory, directory + "-moved")
    _ = symlink(target, directory)
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

    @Test func aCRLFGitignoreKeepsHostSecretsOut() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/proj/.gitignore", ".env\r\nnode_modules/\r\n")
        try fixture.write(fixture.host + "/proj/.env", "TOKEN=secret")
        try fixture.write(fixture.host + "/proj/node_modules/x.js", "x")
        try fixture.write(fixture.host + "/proj/main.js", "m")
        _ = try fixture.upload(fixture.host + "/proj").get()
        #expect(fixture.exists(fixture.workspace + "/proj/.env") == false)
        #expect(fixture.exists(fixture.workspace + "/proj/node_modules") == false)
        #expect(fixture.read(fixture.workspace + "/proj/main.js") == "m")
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

    @Test func refusesASourceParentSwappedForASymlinkAfterPlanning() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/a/data/x", "mine")
        try fixture.write(fixture.outside + "/data/x", "secret")
        let parent = fixture.host + "/a"
        let outside = fixture.outside
        let result = fixture.upload(parent + "/data", afterPlan: { swapForSymlink(parent, to: outside) })
        #expect(isChanged(result))
        #expect(fixture.exists(fixture.workspace + "/data") == false)
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
            ".rv/policy.toml", ".config/rv/x", ".envrc",
            ".MCP.json", ".claude/settings.json", ".Claude/Hooks/x.sh",
        ] {
            #expect(refusal(fixture.upload(fixture.host + "/hook", to: destination)) == .protectedDestination(destination))
        }
        for destination in [".git/hooks/pre-commit", ".git/config", ".git/info/attributes"] {
            #expect(refusal(fixture.upload(fixture.host + "/hook", to: destination)) == .gitDirectory(destination))
        }
        try fixture.write(fixture.host + "/tree/.envrc", "export X=1")
        #expect(refusal(fixture.upload(fixture.host + "/tree", to: ".", gitignore: false)) == .protectedDestination(".envrc"))
        #expect(fixture.exists(fixture.workspace + "/.envrc") == false)
    }

    @Test func refusesAnUploadThroughAGitDirectory() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.host + "/hook", "#!/bin/sh")
        try fixture.write(fixture.host + "/repo/.git/config", "[core]")
        #expect(refusal(fixture.upload(fixture.host + "/hook", to: "sub/.git/hooks/pre-commit")) == .gitDirectory("sub/.git/hooks/pre-commit"))
        #expect(refusal(fixture.upload(fixture.host + "/hook", to: "sub/.Git")) == .gitDirectory("sub/.Git"))
        #expect(refusal(fixture.upload(fixture.host + "/repo/.git", to: "gitcopy")) == .gitDirectory(fixture.host + "/repo/.git"))
        #expect(fixture.exists(fixture.workspace + "/sub") == false)
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

    @Test func refusesADestinationParentSwappedForASymlinkAfterPlanning() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/x.plist", "agent")
        try FileManager.default.createDirectory(atPath: fixture.host + "/a", withIntermediateDirectories: true)
        let parent = fixture.host + "/a"
        let outside = fixture.outside
        let result = fixture.download("x.plist", to: parent + "/x.plist", afterPlan: { swapForSymlink(parent, to: outside) })
        #expect(isChanged(result))
        #expect(fixture.exists(fixture.outside + "/x.plist") == false)
        #expect(fixture.exists(fixture.host + "/a-moved/x.plist") == false)
    }

    @Test func refusesWhenTheParentNoLongerResolvesToTheApprovedOne() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/f", "agent")
        var request = WorkspaceDownloadRequest(
            workspace: fixture.workspace, source: "f", destination: fixture.host + "/f",
            protectedRoots: [fixture.configDir], gitignore: true
        )
        request.approvedParent = fixture.outside
        #expect(isChanged(WorkspaceTransfer.download(request)))
        #expect(fixture.exists(fixture.host + "/f") == false)
        // realpath, as the CLI computes it (Foundation keeps `/var`, realpath gives `/private/var`).
        let real = realpath(fixture.host, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        request.approvedParent = real
        #expect(refusal(WorkspaceTransfer.download(request)) == nil)
    }

    @Test(arguments: [
        ".claude/settings.json", ".claude/settings.local.json", "opencode.json", ".envrc",
        ".vscode/tasks.json", ".mcp.json", ".claude/hooks/pre.sh", ".rv/policy.toml", ".config/rv/x",
    ])
    func refusesNestedGuestConfigThatWouldLandAtTheTop(name: String) throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/sub/ok.txt", "ok")
        try fixture.write(fixture.workspace + "/sub/" + name, "planted")
        // A protected tree (`.claude/hooks`, `.rv`) is named along with the file in it.
        guard case .protectedEntries(let offenders) = refusal(fixture.download("sub", to: fixture.host + "/newproj")) else {
            Issue.record("expected protectedEntries")
            return
        }
        #expect(offenders.last == "newproj/" + name)
        #expect(offenders.allSatisfy { ("newproj/" + name).hasPrefix($0) })
        #expect(fixture.exists(fixture.host + "/newproj") == false)
    }

    @Test func aDestinationNamedLikeAControlDirectoryIsRefused() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/cfg/settings.json", "{}")
        #expect(refusal(fixture.download("cfg", to: fixture.host + "/.claude")) == .protectedEntries([".claude/settings.json"]))
    }

    @Test(arguments: [".git", "sub/.git", "sub/.GIT/hooks", ".git/config"])
    func refusesADownloadSourceThroughAGitDirectory(source: String) throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/.git/config", "[core]\n\tpager = /tmp/x\n")
        try fixture.write(fixture.workspace + "/sub/.GIT/hooks/post-checkout", "#!/bin/sh")
        #expect(refusal(fixture.download(source, to: fixture.host + "/x")) == .gitDirectory(source))
        #expect(fixture.exists(fixture.host + "/x") == false)
    }

    @Test func gitDirectoriesAreAlwaysSkipped() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/sub/ok.txt", "ok")
        try fixture.write(fixture.workspace + "/sub/.git/config", "[core]\n\tfsmonitor = /tmp/x\n")
        try fixture.write(fixture.workspace + "/sub/deep/.GIT/config", "[core]")
        let summary = try fixture.download("sub", to: fixture.host + "/newproj", gitignore: false).get()
        #expect(fixture.exists(fixture.host + "/newproj/.git") == false)
        #expect(fixture.exists(fixture.host + "/newproj/deep/.GIT") == false)
        #expect(fixture.read(fixture.host + "/newproj/ok.txt") == "ok")
        #expect(summary.ignored == 2)
    }

    @Test(arguments: [false, true])
    func neverRemovesADestinationSomeoneElseCreatedAfterPlanning(directory: Bool) throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        if directory {
            try fixture.write(fixture.workspace + "/out/a", "agent")
        } else {
            try fixture.write(fixture.workspace + "/out", "agent")
        }
        let target = fixture.host + "/results"
        let result = fixture.download("out", to: target, afterPlan: {
            if directory {
                try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
                try? Data("mine".utf8).write(to: URL(fileURLWithPath: target + "/keep"))
            } else {
                try? Data("mine".utf8).write(to: URL(fileURLWithPath: target))
            }
        })
        guard case .destinationExists? = refusal(result) else { Issue.record("expected destinationExists, got \(String(describing: refusal(result)))"); return }
        #expect(fixture.read(directory ? target + "/keep" : target) == "mine")
    }

    @Test func ignoredEntriesCountTowardTheNameCap() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/out/.gitignore", "*.log\n")
        try fixture.write(fixture.workspace + "/out/keep.txt", "k")
        for index in 0..<5 { try fixture.write(fixture.workspace + "/out/\(index).log", "l") }
        var limits = WorkspaceTransferLimits.standard
        limits.maxNames = 4
        #expect(refusal(fixture.download("out", to: fixture.host + "/results", limits: limits)) == .tooManyNames(4))
        limits.maxNames = 7
        #expect(refusal(fixture.download("out", to: fixture.host + "/results", limits: limits)) == nil)
    }

    @Test func gitignoreRulesAreCappedAndOversizedFilesRefuse() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/out/.gitignore", "a\nb\nc\n")
        try fixture.write(fixture.workspace + "/out/keep.txt", "k")
        var limits = WorkspaceTransferLimits.standard
        limits.maxIgnoreRules = 2
        #expect(refusal(fixture.download("out", to: fixture.host + "/r1", limits: limits)) == .tooManyIgnoreRules(2))
        limits = .standard
        limits.maxIgnoreBytes = 2
        #expect(refusal(fixture.download("out", to: fixture.host + "/r2", limits: limits)) == .tooManyIgnoreRules(limits.maxIgnoreRules))
        try fixture.write(fixture.workspace + "/big/.gitignore", String(repeating: "x\n", count: 200 * 1024))
        try fixture.write(fixture.workspace + "/big/keep.txt", "k")
        #expect(refusal(fixture.download("big", to: fixture.host + "/r3")) == .tooManyIgnoreRules(WorkspaceTransferLimits.standard.maxIgnoreRules))
    }

    @Test func aDirectorysRulesDoNotLeakToItsSiblings() throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try fixture.write(fixture.workspace + "/out/a/.gitignore", "x\n")
        try fixture.write(fixture.workspace + "/out/a/x", "ignored")
        try fixture.write(fixture.workspace + "/out/b/x", "kept")
        _ = try fixture.download("out", to: fixture.host + "/results").get()
        #expect(fixture.exists(fixture.host + "/results/a/x") == false)
        #expect(fixture.read(fixture.host + "/results/b/x") == "kept")
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

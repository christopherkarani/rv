#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Testing
@testable import RVUndo

// MARK: - Fixtures

/// A throwaway directory, removed by the test that made it.
struct Scratch {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rv-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try #require(UndoKeeper.realPath(base.path))
    }

    var store: UndoStore { UndoStore(root: URL(fileURLWithPath: root + "/store")) }

    func path(_ relative: String) -> String { root + "/" + relative }

    func write(_ relative: String, _ text: String, mode: mode_t = 0o644) throws {
        let url = URL(fileURLWithPath: path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        chmod(url.path, mode)
    }

    func read(_ relative: String) -> String? {
        FileManager.default.contents(atPath: path(relative)).map { String(decoding: $0, as: UTF8.self) }
    }

    func mode(_ relative: String) -> mode_t {
        var info = stat()
        lstat(path(relative), &info)
        return info.st_mode & 0o777
    }

    func isLink(_ relative: String) -> Bool {
        var info = stat()
        return lstat(path(relative), &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    /// `git` in `relative`, with a test identity; returns stdout.
    @discardableResult
    func git(_ arguments: [String], in relative: String = "repo") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path(relative))
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@t"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@t"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A repo with one commit holding `a.txt`.
    func makeRepo() throws {
        try FileManager.default.createDirectory(atPath: path("repo"), withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try write("repo/a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "first"])
    }

    /// A plain repo (a `.git` directory, no git needed) for file copies.
    func makePlainRepo() throws {
        try FileManager.default.createDirectory(atPath: path("repo/.git"), withIntermediateDirectories: true)
    }
}

func request(_ target: UndoTarget, cwd: String, budget: Duration = .seconds(10)) -> UndoRequest {
    UndoRequest(target: target, cwd: cwd, command: "rm -rf build", host: "claude", reason: .watched, budget: budget)
}

let hasGit = FileManager.default.isExecutableFile(atPath: "/usr/bin/git")

// MARK: - Plan

@Suite("Which commands get a copy")
struct UndoPlanTests {
    @Test("resets, discards and clean -f do; soft resets, dry runs and reads do not")
    func gitClasses() {
        #expect(UndoPlan.target(for: .reset(mode: .hard, target: nil)) == .gitWorkingTree)
        #expect(UndoPlan.target(for: .reset(mode: .merge, target: "HEAD~1")) == .gitWorkingTree)
        #expect(UndoPlan.target(for: .discardWorktree(pathspecs: ["."], source: nil)) == .gitWorkingTree)
        #expect(UndoPlan.target(for: .restore(pathspecs: ["."], destination: .worktree, source: nil)) == .gitWorkingTree)
        #expect(UndoPlan.target(for: .switchBranch(name: "x", force: true)) == .gitWorkingTree)
        #expect(UndoPlan.target(for: .clean(force: true, dryRun: false, directories: true)) == .gitUntracked)
        #expect(UndoPlan.target(for: .reset(mode: .soft, target: nil)) == nil)
        #expect(UndoPlan.target(for: .reset(mode: .mixed, target: nil)) == nil)
        #expect(UndoPlan.target(for: .clean(force: true, dryRun: true, directories: false)) == nil)
        #expect(UndoPlan.target(for: .restore(pathspecs: ["."], destination: .index, source: nil)) == nil)
        #expect(UndoPlan.target(for: .switchBranch(name: "x", force: false)) == nil)
    }

    @Test("a delete keeps its targets; secrets are marked; a link is kept as the link")
    func deleteTargets() {
        let plain = FilesystemTarget(apparent: "build", canonical: "/r/build", scope: .insideRepository, kind: .generatedOutput)
        let linked = FilesystemTarget(
            apparent: "out", canonical: "/elsewhere/real", scope: .outsideRepository, kind: .unknown, followedSymlink: true)
        let unplaced = FilesystemTarget(apparent: "~/x", canonical: "~/x", scope: .unknown, kind: .unknown, followedSymlink: true)
        let analysis = SemanticAnalysis.filesystem(.delete(targets: [plain, linked, unplaced], recursive: true, force: true))
        #expect(UndoPlan.target(for: analysis, cwd: "/r") == .paths([
            UndoPath(path: "/r/build"), UndoPath(path: "/r/out"),
        ]))
        let read = SemanticAnalysis.filesystem(.read(targets: [plain]))
        #expect(UndoPlan.target(for: read, cwd: "/r") == nil)
        #expect(UndoPlan.target(for: .unknown, cwd: "/r") == nil)
    }

    @Test("paths normalize without touching the disk")
    func normalize() {
        #expect(UndoPlan.lexicallyNormalized("/a/./b/../c/") == "/a/c")
        #expect(UndoPlan.lexicallyNormalized("/../..") == "/")
    }
}

// MARK: - File copies

@Suite("Kept copies of deleted files")
struct UndoFileTests {
    @Test("a deleted tree comes back whole, modes and links as they were, nothing overwritten")
    func roundTrip() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/build/out.txt", "a\nb\n")
        try scratch.write("repo/build/key.pem", "secret\n", mode: 0o600)
        try scratch.write("outside.txt", "not ours\n")
        symlink(scratch.path("outside.txt"), scratch.path("repo/build/link"))

        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/build"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .files)
        #expect(kept.paths == ["build"])
        #expect(kept.tally.files == 2)
        #expect(kept.tally.lines == 3)
        #expect(kept.notes.isEmpty)

        try FileManager.default.removeItem(atPath: scratch.path("repo/build"))
        try scratch.write("repo/build/out.txt", "new\n")
        let outcome = try UndoRestore.restore(kept, from: scratch.store, into: scratch.path("repo"))
        // `build` exists again (the agent made a new one): left alone.
        #expect(outcome == .files(restored: 0, leftInPlace: ["build"]))
        #expect(scratch.read("repo/build/out.txt") == "new\n")

        try FileManager.default.removeItem(atPath: scratch.path("repo/build"))
        let again = try UndoRestore.restore(kept, from: scratch.store, into: scratch.path("repo"))
        #expect(again == .files(restored: 2, leftInPlace: []))
        #expect(scratch.read("repo/build/out.txt") == "a\nb\n")
        #expect(scratch.mode("repo/build/key.pem") == 0o600)
        #expect(scratch.isLink("repo/build/link"))
        // The link was never followed: what it points at was not copied.
        let data = scratch.store.dataDirectory(of: kept).path
        #expect(scratch.isLink(String(data.dropFirst(scratch.root.count + 1)) + "/build/link"))
    }

    @Test("the store and every copy are owner-only; a secrets file keeps its owner-only bits")
    func ownerOnly() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/notes/.env", "TOKEN=x\n", mode: 0o600)
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/notes"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .files)
        #expect(scratch.mode("store") == 0o700)
        #expect(scratch.mode("store/\(kept.id)") == 0o700)
        #expect(scratch.mode("store/\(kept.id)/manifest.json") == 0o600)
        #expect(scratch.mode("store/\(kept.id)/data") == 0o700)
        #expect(scratch.mode("store/\(kept.id)/data/notes/.env") == 0o600)
    }

    @Test("paths rv marks as secrets are never copied")
    func secretsAreSkipped() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/.env", "TOKEN=x\n", mode: 0o600)
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/.env"), isSecret: true)]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .skipped)
        #expect(kept.notes == ["Not copied: \(scratch.path("repo/.env")) is a secrets file."])
        #expect(FileManager.default.fileExists(atPath: scratch.path("store/\(kept.id)/data")) == false)
    }

    @Test("a link in the path that leads out of the repository is never followed")
    func linkOutOfRepo() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("home/private.txt", "mine\n")
        symlink(scratch.path("home"), scratch.path("repo/h"))
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/h/private.txt")), UndoPath(path: scratch.path("home"))]),
                    cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .skipped)
        #expect(kept.notes.count == 2)
        #expect(kept.notes.allSatisfy { $0.contains("outside the repository") })
    }

    @Test("a delete of the link itself keeps the link, not what it points at")
    func linkItself() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("big/file.bin", String(repeating: "x", count: 1000))
        symlink(scratch.path("big"), scratch.path("repo/big"))
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/big"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .files)
        #expect(kept.tally.files == 0)
        #expect(kept.tally.bytes == 0)
    }

    @Test("a copy over the size limit is skipped with a note, and leaves nothing behind")
    func sizeCap() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/data/a.bin", String(repeating: "x", count: 4096))
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/data"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false, maxBytes: 1024)
        #expect(kept.kind == .skipped)
        #expect(kept.notes.first?.hasPrefix("Too big to keep a copy (4.0 KB") == true)
        #expect(FileManager.default.fileExists(atPath: scratch.path("store/\(kept.id)/data")) == false)
        #expect(scratch.store.list().map(\.id) == [kept.id])
    }

    @Test("out of time is skipped with a note")
    func deadline() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/data/a.txt", "x\n")
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/data"))]), cwd: scratch.path("repo"), budget: .zero),
            in: scratch.store, clones: false)
        #expect(kept.kind == .skipped)
        #expect(kept.notes == [UndoSkip.outOfTime.note])
    }

    @Test("outside a repository nothing is kept")
    func noRepository() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("loose/a.txt", "x\n")
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("loose/a.txt"))]), cwd: scratch.path("loose")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .skipped)
        #expect(kept.notes == [UndoSkip.notInRepository.note])
    }

    @Test("a copy restores only into the repository it came from")
    func otherRepository() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try FileManager.default.createDirectory(atPath: scratch.path("other/.git"), withIntermediateDirectories: true)
        try scratch.write("repo/x.txt", "x\n")
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/x.txt"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(throws: UndoRestoreRefusal.otherRepository(scratch.path("repo"))) {
            _ = try UndoRestore.restore(kept, from: scratch.store, into: scratch.path("other"))
        }
    }
}

// MARK: - Store

@Suite("The undo store")
struct UndoStoreTests {
    @Test("copies older than 7 days are pruned; newer ones stay")
    func prune() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/x.txt", "x\n")
        let now = Date()
        let old = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/x.txt"))]), cwd: scratch.path("repo")),
            in: scratch.store, now: now.addingTimeInterval(-8 * 86_400), clones: false)
        let recent = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/x.txt"))]), cwd: scratch.path("repo")),
            in: scratch.store, now: now.addingTimeInterval(-6 * 86_400), clones: false)
        // Keeping prunes as it goes, relative to the keep's own time.
        #expect(Set(scratch.store.list().map(\.id)) == [old.id, recent.id])
        let pruned = scratch.store.prune(now: now)
        #expect(pruned.map(\.id) == [old.id])
        #expect(scratch.store.list().map(\.id) == [recent.id])
        #expect(FileManager.default.fileExists(atPath: scratch.path("store/\(old.id)")) == false)
    }

    @Test("ids are ours only in their own shape")
    func ids() {
        let id = UndoStore.makeID(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(UndoStore.isID(id))
        #expect(id.hasPrefix("20270115-"))
        #expect(UndoStore.isID("../../etc/passwd-xx") == false)
        #expect(UndoStore.isID("") == false)
    }
}

// MARK: - Git

@Suite("Kept copies of git work", .enabled(if: hasGit))
struct UndoGitTests {
    @Test("unsaved work a reset --hard threw away comes back on a new branch")
    func resetRoundTrip() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/a.txt", "one\ntwo\nthree\n")
        try scratch.write("repo/b.txt", "new file\n")
        try scratch.git(["add", "b.txt"])

        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .git)
        #expect(kept.notes.isEmpty)
        #expect(kept.tally.files == 2)
        #expect(kept.tally.lines == 3)
        let ref = try #require(kept.git?.ref)
        #expect(try scratch.git(["rev-parse", "--verify", "-q", ref]).isEmpty == false)

        try scratch.git(["reset", "-q", "--hard"])
        #expect(scratch.read("repo/a.txt") == "one\n")

        let utc = try #require(TimeZone(identifier: "UTC"))
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let outcome = try UndoRestore.restore(
            kept, from: scratch.store, into: scratch.path("repo"), now: at, timeZone: utc)
        #expect(outcome == .branch("rv/restore-0800"))
        #expect(scratch.read("repo/a.txt") == "one\ntwo\nthree\n")
        #expect(scratch.read("repo/b.txt") == "new file\n")
        #expect(try scratch.git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            == "rv/restore-0800")
    }

    @Test("a restore refuses to run over unsaved changes")
    func restoreNeverOverwrites() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/a.txt", "one\ntwo\n")
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        try scratch.write("repo/a.txt", "someone else's work\n")
        #expect(throws: UndoRestoreRefusal.unsavedChanges) {
            _ = try UndoRestore.restore(kept, from: scratch.store, into: scratch.path("repo"))
        }
        #expect(scratch.read("repo/a.txt") == "someone else's work\n")
    }

    @Test("a repository whose config runs filters gets no copy, and its filter never runs")
    func filtersRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        let marker = scratch.path("ran")
        try scratch.git(["config", "filter.evil.clean", "touch \(marker); cat"])
        try scratch.write("repo/.gitattributes", "*.txt filter=evil\n")
        try scratch.write("repo/a.txt", "changed\n")
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .skipped)
        #expect(kept.notes == [UndoSkip.gitRunsRepoCommands.note])
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test("repository hooks never run while rv keeps a copy")
    func hooksNeverRun() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        let marker = scratch.path("hook-ran")
        let hook = scratch.path("repo/.git/hooks/reference-transaction")
        try FileManager.default.createDirectory(atPath: scratch.path("repo/.git/hooks"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\ntouch \(marker)\n".utf8).write(to: URL(fileURLWithPath: hook))
        chmod(hook, 0o755)
        try scratch.write("repo/a.txt", "changed\n")
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .git)
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test("untracked files git clean would remove are copied")
    func untracked() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/scratch/notes.md", "draft\n")
        let kept = UndoKeeper.keep(request(.gitUntracked, cwd: scratch.path("repo")), in: scratch.store, clones: false)
        #expect(kept.kind == .files)
        #expect(kept.paths == ["scratch/notes.md"])
        try scratch.git(["clean", "-fdq"])
        #expect(scratch.read("repo/scratch/notes.md") == nil)
        let outcome = try UndoRestore.restore(kept, from: scratch.store, into: scratch.path("repo"))
        #expect(outcome == .files(restored: 1, leftInPlace: []))
        #expect(scratch.read("repo/scratch/notes.md") == "draft\n")
    }

    @Test("pruning drops the git ref with the copy")
    func pruneDropsRef() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/a.txt", "changed\n")
        let old = UndoKeeper.keep(
            request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store,
            now: Date().addingTimeInterval(-8 * 86_400))
        let ref = try #require(old.git?.ref)
        // The next keep prunes the old copy and its ref.
        _ = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(try scratch.git(["for-each-ref", ref]).isEmpty)
    }
}

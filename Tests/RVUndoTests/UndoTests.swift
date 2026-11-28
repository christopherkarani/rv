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
    /// `reading` adds a copy's objects (in the store) as an alternate.
    @discardableResult
    func git(_ arguments: [String], in relative: String = "repo", reading copy: UndoManifest? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path(relative))
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@t"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@t"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
        if let copy { env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = store.objectsDirectory(of: copy.id).path }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Every object file and ref name in the repository's `.git`, so a
    /// test can see that a keep added none.
    func gitObjectsAndRefs() throws -> Set<String> {
        let git = path("repo/.git")
        var names = Set<String>()
        for folder in ["objects", "refs"] {
            let enumerator = FileManager.default.enumerator(atPath: git + "/" + folder)
            while let name = enumerator?.nextObject() as? String { names.insert(folder + "/" + name) }
        }
        if let packed = FileManager.default.contents(atPath: git + "/packed-refs") {
            names.insert("packed-refs:" + String(decoding: packed, as: UTF8.self))
        }
        return names
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
        try scratch.write("repo/notes/private.txt", "mine\n", mode: 0o600)
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/notes"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .files)
        #expect(scratch.mode("store") == 0o700)
        #expect(scratch.mode("store/\(kept.id)") == 0o700)
        #expect(scratch.mode("store/\(kept.id)/manifest.json") == 0o600)
        #expect(scratch.mode("store/\(kept.id)/data") == 0o700)
        #expect(scratch.mode("store/\(kept.id)/data/notes/private.txt") == 0o600)
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

    @Test("outside a repository nothing is kept, and nothing is written")
    func noRepository() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("loose/a.txt", "x\n")
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("loose/a.txt"))]), cwd: scratch.path("loose")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .skipped)
        #expect(kept.notes == [UndoSkip.notInRepository.note])
        #expect(FileManager.default.fileExists(atPath: scratch.path("store")) == false)
    }

    @Test("secrets inside a deleted folder are left out, with a note; the rest is kept")
    func secretsInsideATree() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/conf/app.toml", "port = 1\n")
        try scratch.write("repo/conf/.env", "TOKEN=x\n", mode: 0o600)
        try scratch.write("repo/conf/deep/id_rsa", "KEY\n", mode: 0o600)
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/conf"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .files)
        #expect(kept.tally.files == 1)
        #expect(kept.notes == [
            "Not copied: conf/.env is a secrets file.", "Not copied: conf/deep/id_rsa is a secrets file.",
        ])
        #expect(scratch.read("store/\(kept.id)/data/conf/app.toml") == "port = 1\n")
        #expect(FileManager.default.fileExists(atPath: scratch.path("store/\(kept.id)/data/conf/.env")) == false)
        #expect(FileManager.default.fileExists(atPath: scratch.path("store/\(kept.id)/data/conf/deep/id_rsa")) == false)
    }

    @Test("a tree nested deeper than the limit is skipped with a note")
    func depthCap() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        let deep = (0...UndoLimits.maxDepth).map { _ in "d" }.joined(separator: "/")
        try scratch.write("repo/nest/\(deep)/f.txt", "x\n")
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/nest"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .skipped)
        #expect(kept.notes == [UndoSkip.tooDeep(levels: UndoLimits.maxDepth).note])
    }

    @Test("a directory with more entries than the limit is stopped while it is read")
    func entryCapInsideReaddir() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        for number in 0..<600 { try scratch.write("repo/many/f\(number)", "") }
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/many"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false, maxEntries: 300)
        #expect(kept.kind == .skipped)
        #expect(kept.notes == [UndoSkip.tooManyFiles(count: 300).note])
    }

    @Test("a file with other hard links is not copied under this name")
    func hardLinkInTree() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("key", "SECRET\n", mode: 0o600)
        try scratch.write("repo/out/ok.txt", "ok\n")
        link(scratch.path("key"), scratch.path("repo/out/innocent.txt"))
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/out"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.kind == .files)
        #expect(kept.tally.files == 1)
        #expect(kept.notes == [UndoSkip.hardLinked("out/innocent.txt").note])
        #expect(FileManager.default.fileExists(atPath: scratch.path("store/\(kept.id)/data/out/innocent.txt")) == false)
    }

    @Test("a path deeper than the limit is refused before anything is opened")
    func deepPath() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        let deep = (0...UndoLimits.maxDepth).map { _ in "d" }.joined(separator: "/")
        try scratch.write("repo/\(deep)/f.txt", "x\n")
        #expect(UndoKeeper.place(UndoPath(path: scratch.path("repo/\(deep)/f.txt")), in: scratch.path("repo"))
            == .failure(.tooDeep(levels: UndoLimits.maxDepth)))
        // A target near the limit leaves only what is left of it for the walk.
        let near = (0..<(UndoLimits.maxDepth - 2)).map { _ in "d" }.joined(separator: "/")
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/\(near)"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        #expect(kept.notes == [UndoSkip.tooDeep(levels: UndoLimits.maxDepth).note])
    }

    @Test("the request's own deadline counts: one already past keeps nothing and runs nothing")
    func requestDeadline() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/x.txt", "x\n")
        var late = request(.paths([UndoPath(path: scratch.path("repo/x.txt"))]), cwd: scratch.path("repo"))
        late.deadline = .now - .milliseconds(1)
        let kept = UndoKeeper.keep(late, in: scratch.store, clones: false)
        #expect(kept.notes == [UndoSkip.outOfTime.note])
        #expect(FileManager.default.fileExists(atPath: scratch.path("store")) == false)
        // Two requests for the same copy are equal whenever they were made.
        var early = late
        early.deadline = .now + .seconds(5)
        #expect(early == late)
    }

    @Test("no git run starts past its deadline, and a long index listing stops at it")
    func gitDeadlines() throws {
        let runner = UndoGit(executable: URL(fileURLWithPath: "/usr/bin/git"), repository: "/", deadline: .now - .seconds(1))
        #expect(throws: UndoSkip.outOfTime) { _ = try runner.run(["--version"]) }
        let entry = "100644 \(String(repeating: "a", count: 40)) 0\tp\0"
            + "  ctime: 1:2\n  mtime: 1:0\n  dev: 1\tino: 2\n  uid: 0\tgid: 0\n  size: 1\tflags: 0\n"
        #expect(UndoIndexListing.parse(Data(entry.utf8), deadline: .now - .seconds(1)) == nil)
        #expect(UndoIndexListing.parse(Data(entry.utf8), deadline: .now + .seconds(5))?.count == 1)
    }

    @Test("rvd's git reaches no transport, helper or parent repository; a restore is the person's own git")
    func environments() {
        let base = ["HOME": "/h", "PATH": "/opt/bin:/usr/bin", "GIT_DIR": "/elsewhere", "LANG": "C"]
        let keeper = UndoGit.environment(mode: .keeper, root: "/r/app", base: base)
        #expect(keeper["GIT_NO_LAZY_FETCH"] == "1")
        #expect(keeper["GIT_ALLOW_PROTOCOL"] == "none")
        #expect(keeper["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(keeper["GIT_DIR"] == "/r/app/.git")
        #expect(keeper["GIT_WORK_TREE"] == "/r/app")
        #expect(keeper["GIT_CEILING_DIRECTORIES"] == "/r")
        #expect(keeper["PATH"] == "/usr/bin:/bin")
        for flag in ["core.hooksPath=/dev/null", "credential.helper=", "core.sshCommand=/bin/false", "protocol.allow=never"] {
            #expect(UndoGit.hardening.contains(flag))
        }
        let person = UndoGit.environment(mode: .person, root: "/r/app", base: base)
        #expect(person["PATH"] == "/opt/bin:/usr/bin")
        #expect(person["GIT_CONFIG_GLOBAL"] == nil)
        #expect(person["GIT_DIR"] == "/r/app/.git")
        #expect(UndoGit.personHardening.contains("core.hooksPath=/dev/null"))
    }

    @Test("partial clones, promisor remotes and unknown extensions are refused by name")
    func configProblems() {
        #expect(UndoRepository.configProblem(["core.bare", "extensions.objectformat"]) == nil)
        #expect(UndoRepository.configProblem(["extensions.partialclone"]) == "it is a partial clone")
        #expect(UndoRepository.configProblem(["remote.my.fork.promisor"]) == "it is a partial clone")
        #expect(UndoRepository.configProblem(["extensions.worktreeconfig"]) == "it uses extensions.worktreeconfig")
    }

    @Test("nested paths in one set are copied once, inside their folder")
    func outermost() {
        #expect(UndoKeeper.outermost([["a", "b"], ["b"], ["a"], ["a", "b", "c"], ["ab"]]) == [["a"], ["ab"], ["b"]])
    }

    @Test("a manifest edited after rv wrote it is refused, and .git is never restored")
    func tamperedManifest() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/x.txt", "x\n")
        let kept = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/x.txt"))]), cwd: scratch.path("repo")),
            in: scratch.store, clones: false)
        for path in [".git/hooks/post-checkout", "sub/.GIT/config", "../x.txt", "/etc/x", "a//b", ""] {
            var edited = kept
            edited.paths = [path]
            #expect(throws: UndoRestoreRefusal.notOurs) {
                _ = try UndoRestore.restore(edited, from: scratch.store, into: scratch.path("repo"))
            }
        }
        for head in ["HEAD~1", "--exec=x", "abc", String(repeating: "A", count: 40)] {
            var edited = kept
            edited.kind = .git
            edited.git = .init(head: head, stash: nil)
            #expect(throws: UndoRestoreRefusal.notOurs) {
                _ = try UndoRestore.restore(edited, from: scratch.store, into: scratch.path("repo"))
            }
        }
        var badStash = kept
        badStash.kind = .git
        badStash.git = .init(head: String(repeating: "a", count: 40), stash: "refs/heads/main")
        #expect(throws: UndoRestoreRefusal.notOurs) {
            _ = try UndoRestore.restore(badStash, from: scratch.store, into: scratch.path("repo"))
        }
        // A .git planted inside a kept folder is not put back.
        try scratch.write("store/\(kept.id)/data/x.txt", "")
        try FileManager.default.removeItem(atPath: scratch.path("store/\(kept.id)/data/x.txt"))
        try scratch.write("store/\(kept.id)/data/x.txt/.git/hooks/post-checkout", "#!/bin/sh\n")
        try scratch.write("store/\(kept.id)/data/x.txt/ok.txt", "ok\n")
        try FileManager.default.removeItem(atPath: scratch.path("repo/x.txt"))
        _ = try UndoRestore.restore(kept, from: scratch.store, into: scratch.path("repo"))
        #expect(scratch.read("repo/x.txt/ok.txt") == "ok\n")
        #expect(FileManager.default.fileExists(atPath: scratch.path("repo/x.txt/.git")) == false)
    }

    @Test("terminal-unsafe text is dropped")
    func plainText() {
        #expect(UndoText.plain("a\u{1B}[31mb\u{9B}c\u{202E}d\u{2067}e\u{200F}f\u{2028}g\u{7F}h\ti") == "a[31mbcdefghi")
        #expect(UndoText.plain("caf\u{E9} · 日本") == "caf\u{E9} · 日本")
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

// MARK: - Index listing

@Suite("Reading the index")
struct UndoIndexTests {
    @Test("ls-files --debug -z parses, and only a changed or racy entry needs hashing")
    func parseAndCompare() throws {
        let text = "100644 \(String(repeating: "a", count: 40)) 0\tdir/a b.txt\0"
            + "  ctime: 1:2\n  mtime: 1700000000:500\n  dev: 1\tino: 2\n  uid: 0\tgid: 0\n  size: 12\tflags: 0\n"
            + "120000 \(String(repeating: "b", count: 40)) 0\tl\0"
            + "  ctime: 1:2\n  mtime: 5:0\n  dev: 1\tino: 2\n  uid: 0\tgid: 0\n  size: 3\tflags: 40000000\n"
        let entries = try #require(UndoIndexListing.parse(Data(text.utf8)))
        #expect(entries.map(\.path) == ["dir/a b.txt", "l"])
        #expect(entries[1].flags & UndoIndexEntry.leaveAlone != 0)
        let entry = entries[0]
        let written = (seconds: 1_700_000_100, nanoseconds: 0)
        let same = UndoWorktreeFile.file(size: 12, mtimeSeconds: 1_700_000_000, mtimeNanoseconds: 500, executable: false)
        #expect(same.mayDiffer(from: entry, indexWritten: written) == false)
        #expect(UndoWorktreeFile.file(size: 13, mtimeSeconds: 1_700_000_000, mtimeNanoseconds: 500, executable: false)
            .mayDiffer(from: entry, indexWritten: written))
        #expect(UndoWorktreeFile.file(size: 12, mtimeSeconds: 1_700_000_000, mtimeNanoseconds: 500, executable: true)
            .mayDiffer(from: entry, indexWritten: written))
        #expect(UndoWorktreeFile.link(size: 12, mtimeSeconds: 1_700_000_000, mtimeNanoseconds: 500)
            .mayDiffer(from: entry, indexWritten: written))
        #expect(UndoWorktreeFile.missing.mayDiffer(from: entry, indexWritten: written))
        // Changed in the same second the index was written: hashed.
        #expect(same.mayDiffer(from: entry, indexWritten: (1_700_000_000, 0)))
        #expect(UndoIndexListing.parse(Data("100644 x 0\tp\0  ctime: 1\n".utf8)) == nil)
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

    static func manifest(_ id: String, _ kind: UndoManifest.Kind, daysAgo: Double, bytes: UInt64 = 0, now: Date)
        -> UndoManifest {
        var tally = UndoTally()
        tally.bytes = bytes
        return UndoManifest(
            schema: 1, id: id, createdAt: now.addingTimeInterval(-daysAgo * 86_400), host: "claude", command: "rm",
            reason: .watched, repoRoot: "/r", kind: kind, git: nil, paths: [], tally: tally, notes: [])
    }

    @Test("the store keeps at most 50 copies and 2 GB, oldest out first, skipped notes capped first")
    func quota() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let copies = (0..<55).map { Self.manifest("c\($0)", .files, daysAgo: Double($0) / 100, now: now) }
        #expect(UndoStore.evictions(copies, now: now).map(\.id) == ["c54", "c53", "c52", "c51", "c50"])
        let big = [
            Self.manifest("new", .files, daysAgo: 0.1, bytes: 1_500 << 20, now: now),
            Self.manifest("old", .files, daysAgo: 0.2, bytes: 1_000 << 20, now: now),
            Self.manifest("git", .git, daysAgo: 0.3, now: now),
        ]
        #expect(UndoStore.evictions(big, now: now).map(\.id) == ["old"])
        // A flood of skipped requests never pushes a real copy out.
        let flood = [Self.manifest("real", .files, daysAgo: 1, now: now)]
            + (0..<60).map { Self.manifest("s\($0)", .skipped, daysAgo: Double($0) / 1_000, now: now) }
        let going = UndoStore.evictions(flood, now: now).map(\.id)
        #expect(going.contains("real") == false)
        #expect(going.count == 50)
        #expect(UndoStore.evictions([Self.manifest("x", .git, daysAgo: 8, now: now)], now: now).map(\.id) == ["x"])
        // Age order across kinds: the oldest goes, whatever it is.
        let mixed = [Self.manifest("oldfile", .files, daysAgo: 2, now: now)]
            + (0..<50).map { Self.manifest("g\($0)", .git, daysAgo: Double($0) / 100, now: now) }
        #expect(UndoStore.evictions(mixed, now: now).map(\.id) == ["oldfile"])
    }

    @Test("a prune past its deadline removes nothing")
    func boundedPrune() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makePlainRepo()
        try scratch.write("repo/x.txt", "x\n")
        let old = UndoKeeper.keep(
            request(.paths([UndoPath(path: scratch.path("repo/x.txt"))]), cwd: scratch.path("repo")),
            in: scratch.store, now: Date().addingTimeInterval(-8 * 86_400), clones: false)
        #expect(scratch.store.prune(now: Date(), deadline: .now - .seconds(1)).isEmpty)
        #expect(scratch.store.list().map(\.id) == [old.id])
        #expect(scratch.store.prune(now: Date()).map(\.id) == [old.id])
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
        // Counted from what rv handed git (no diff runs): both files, their bytes.
        #expect(kept.tally.files == 2)
        #expect(kept.tally.lines == nil)
        // Bytes rv handed git (the staged file was already in the repository).
        #expect(kept.tally.bytes == UInt64("one\ntwo\nthree\n".utf8.count))
        #expect(kept.storedBytes == kept.tally.bytes)
        // Kept in the store, not the repository.
        let stash = try #require(kept.git?.stash)
        #expect(try scratch.git(["cat-file", "-t", stash]).isEmpty)
        #expect(try scratch.git(["cat-file", "-t", stash], reading: kept) == "commit\n")

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

    @Test("a repository's clean filter never runs: rv hands git the bytes as they are")
    func filtersNeverRun() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        let marker = scratch.path("ran")
        try scratch.git(["config", "filter.evil.clean", "touch \(marker); cat"])
        try scratch.git(["config", "filter.evil.smudge", "cat"])
        try scratch.write("repo/.gitattributes", "*.txt filter=evil\n")
        try scratch.write("repo/a.txt", "changed\n")
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(FileManager.default.fileExists(atPath: marker) == false)
        #expect(kept.kind == .git)
        let stash = try #require(kept.git?.stash)
        #expect(try scratch.git(["cat-file", "blob", stash + ":a.txt"], reading: kept) == "changed\n")
    }

    @Test("the person's index is never written, and no lock is left in the repository")
    func indexUntouched() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/a.txt", "changed\n")
        try scratch.write("repo/b.txt", "staged\n")
        try scratch.git(["add", "b.txt"])
        let before = FileManager.default.contents(atPath: scratch.path("repo/.git/index"))
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .git)
        #expect(FileManager.default.contents(atPath: scratch.path("repo/.git/index")) == before)
        #expect(FileManager.default.fileExists(atPath: scratch.path("repo/.git/index.lock")) == false)
        #expect(FileManager.default.fileExists(atPath: scratch.path("store/\(kept.id)/stage")) == false)
    }

    @Test("deleted, re-moded and linked tracked files come back as they were")
    func shapesRoundTrip() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/gone.txt", "bye\n")
        try scratch.write("repo/run.sh", "echo\n")
        symlink("a.txt", scratch.path("repo/link"))
        try scratch.git(["add", "gone.txt", "run.sh", "link"])
        try scratch.git(["commit", "-q", "-m", "more"])
        try FileManager.default.removeItem(atPath: scratch.path("repo/gone.txt"))
        chmod(scratch.path("repo/run.sh"), 0o755)
        try FileManager.default.removeItem(atPath: scratch.path("repo/link"))
        symlink("run.sh", scratch.path("repo/link"))
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .git)
        #expect(kept.tally.files >= 2)
        try scratch.git(["reset", "-q", "--hard"])
        _ = try UndoRestore.restore(kept, from: scratch.store, into: scratch.path("repo"))
        #expect(scratch.read("repo/gone.txt") == nil)
        #expect(scratch.mode("repo/run.sh") & 0o100 != 0)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: scratch.path("repo/link"))
        #expect(target == "run.sh")
    }

    @Test("a reset of a clean tree records nothing, so it can never crowd real copies out")
    func cleanTree() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .skipped)
        #expect(kept.notes == [UndoKeeper.nothingUnsavedNote])
        #expect(scratch.store.list().isEmpty)
        #expect(try scratch.git(["for-each-ref", "refs/rv"]).isEmpty)
    }

    @Test("a changed tracked secrets file is not read; the rest is kept, with a note")
    func trackedSecret() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/.env", "A=1\n")
        try scratch.git(["add", ".env"])
        try scratch.git(["commit", "-q", "-m", "env"])
        try scratch.write("repo/.env", "A=secret\n")
        try scratch.write("repo/a.txt", "changed\n")
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .git)
        #expect(kept.notes == ["Not copied: .env is a secrets file."])
        let stash = try #require(kept.git?.stash)
        #expect(try scratch.git(["cat-file", "blob", stash + ":.env"], reading: kept) == "A=1\n")
        #expect(try scratch.git(["cat-file", "blob", stash + ":a.txt"], reading: kept) == "changed\n")
    }

    @Test("untracked secrets are left out of a clean copy, and too many untracked files are refused up front")
    func untrackedLimits() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/new/.npmrc", "token\n")
        try scratch.write("repo/new/notes.md", "draft\n")
        let kept = UndoKeeper.keep(request(.gitUntracked, cwd: scratch.path("repo")), in: scratch.store, clones: false)
        #expect(kept.paths == ["new/notes.md"])
        #expect(kept.notes == ["Not copied: new/.npmrc is a secrets file."])
        for number in 0..<5 { try scratch.write("repo/more/f\(number)", "") }
        let refused = UndoKeeper.keep(
            request(.gitUntracked, cwd: scratch.path("repo")), in: scratch.store, clones: false, maxEntries: 3)
        #expect(refused.kind == .skipped)
        #expect(refused.notes == [UndoSkip.tooManyFiles(count: 3).note])
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

    @Test("a keep adds no ref and no object to the repository; pruning is removing its folder")
    func keepsNothingInRepository() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/a.txt", "changed\n")
        try scratch.write("repo/new.txt", "added\n")
        try scratch.git(["add", "new.txt"])
        let before = try scratch.gitObjectsAndRefs()
        let old = UndoKeeper.keep(
            request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store,
            now: Date().addingTimeInterval(-8 * 86_400))
        #expect(old.kind == .git)
        #expect(try scratch.gitObjectsAndRefs() == before)
        #expect(try scratch.git(["for-each-ref"]).contains("refs/rv") == false)
        let objects = try FileManager.default.subpathsOfDirectory(atPath: scratch.store.objectsDirectory(of: old.id).path)
        #expect(objects.contains { $0.count == 41 })
        // `rv undo`'s prune drops the old copy: its folder, nothing else.
        UndoKeeper.prune(scratch.store)
        #expect(scratch.store.list().isEmpty)
        #expect(FileManager.default.fileExists(atPath: scratch.path("store/\(old.id)")) == false)
        #expect(try scratch.gitObjectsAndRefs() == before)
    }

    @Test("a restore takes the kept objects from the store, and the result stays whole once the copy is pruned")
    func restoreFromStoreObjects() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/a.txt", "kept only in the store\n")
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        let stash = try #require(kept.git?.stash)
        try scratch.git(["reset", "-q", "--hard"])
        #expect(try scratch.git(["cat-file", "-t", stash]).isEmpty)
        _ = try UndoRestore.restore(kept, from: scratch.store, into: scratch.path("repo"))
        #expect(scratch.read("repo/a.txt") == "kept only in the store\n")
        // The objects came into the repository: gone from the store, still whole.
        try FileManager.default.removeItem(atPath: scratch.path("store"))
        #expect(try scratch.git(["cat-file", "-t", stash]) == "commit\n")
        #expect(try scratch.git(["cat-file", "blob", stash + ":a.txt"]) == "kept only in the store\n")
        try scratch.git(["add", "a.txt"])
        #expect(try scratch.git(["write-tree"]).isEmpty == false)
    }

    /// Sets up the reviewer's partial-clone repository: a lazy fetch would
    /// run `touch <marker>` through the `ext::` transport.
    static func makePartialClone(_ scratch: Scratch, marker: String) throws {
        try scratch.git(["config", "core.repositoryformatversion", "1"])
        try scratch.git(["config", "extensions.partialClone", "origin"])
        try scratch.git(["config", "remote.origin.promisor", "true"])
        try scratch.git(["config", "remote.origin.url", "ext::sh -c touch% \(marker)"])
        try scratch.git(["config", "protocol.ext.allow", "always"])
    }

    @Test("a partial clone is refused, and its lazy fetch never runs")
    func partialCloneRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        let marker = scratch.path("PWNED")
        try Self.makePartialClone(scratch, marker: marker)
        try scratch.write("repo/a.txt", "changed\n")
        let head = try scratch.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(
            atPath: scratch.path("repo/.git/objects/\(head.prefix(2))/\(head.dropFirst(2))"))
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .skipped)
        #expect(kept.notes == [UndoSkip.unsafeRepository("it is a partial clone").note])
        let untracked = UndoKeeper.keep(request(.gitUntracked, cwd: scratch.path("repo")), in: scratch.store)
        #expect(untracked.kind == .skipped)
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test("even past the config check, git's environment blocks the lazy fetch")
    func lazyFetchBlockedByEnvironment() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        let marker = scratch.path("PWNED")
        try Self.makePartialClone(scratch, marker: marker)
        let head = try scratch.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(
            atPath: scratch.path("repo/.git/objects/\(head.prefix(2))/\(head.dropFirst(2))"))
        let runner = UndoGit(
            executable: URL(fileURLWithPath: "/usr/bin/git"), repository: scratch.path("repo"), deadline: .now + .seconds(10))
        _ = try? runner.run(["rev-parse", "--verify", "-q", "HEAD^{commit}"])
        _ = try? runner.run(["cat-file", "-p", head])
        _ = try? runner.run(["diff", "--numstat", head, "HEAD"])
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test("a .git that is a link or a gitdir file is never used, and rv never walks up to a parent repository")
    func gitRedirectsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/sub/.git", "gitdir: \(scratch.path("repo/.git"))\n")
        try scratch.write("repo/sub/x.txt", "x\n")
        try FileManager.default.createDirectory(atPath: scratch.path("linked"), withIntermediateDirectories: true)
        symlink(scratch.path("repo/.git"), scratch.path("linked/.git"))
        for cwd in [scratch.path("repo/sub"), scratch.path("linked")] {
            #expect(UndoKeeper.repositoryRoot(from: cwd) == nil)
            let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: cwd), in: scratch.store)
            #expect(kept.notes == [UndoSkip.notInRepository.note])
        }
        #expect(FileManager.default.fileExists(atPath: scratch.path("store")) == false)
        #expect(try scratch.git(["for-each-ref", "refs/rv"]).isEmpty)
    }

    @Test("object or ref folders that lead out of the repository, and alternates, are refused")
    func linkedGitFoldersRefused() throws {
        let cases: [(String, (Scratch) throws -> Void)] = [
            ("it borrows objects (alternates)", { try $0.write("repo/.git/objects/info/alternates", "/elsewhere\n") }),
            (".git/packed-refs is not a plain file", { scratch in
                try FileManager.default.createDirectory(atPath: scratch.path("out"), withIntermediateDirectories: true)
                symlink(scratch.path("out/target"), scratch.path("repo/.git/packed-refs"))
            }),
            (".git/objects/zz is a link", { scratch in
                try FileManager.default.createDirectory(atPath: scratch.path("out"), withIntermediateDirectories: true)
                symlink(scratch.path("out"), scratch.path("repo/.git/objects/zz"))
            }),
        ]
        for (reason, setUp) in cases {
            let scratch = try Scratch()
            defer { scratch.remove() }
            try scratch.makeRepo()
            try setUp(scratch)
            try scratch.write("repo/a.txt", "changed\n")
            let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
            #expect(kept.notes == [UndoSkip.unsafeRepository(reason).note])
            let outside = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path("out"))) ?? []
            #expect(outside.isEmpty)
        }
    }

    @Test("a packed-refs, HEAD, config or index that is not a plain file is refused, and its target is never written")
    func gitFilesMustBePlain() throws {
        for file in UndoRepository.plainFiles {
            let scratch = try Scratch()
            defer { scratch.remove() }
            try scratch.makeRepo()
            try scratch.git(["pack-refs", "--all"])
            let original = scratch.read("repo/.git/" + file)
            try FileManager.default.moveItem(atPath: scratch.path("repo/.git/" + file), toPath: scratch.path("target"))
            symlink(scratch.path("target"), scratch.path("repo/.git/" + file))
            try scratch.write("repo/a.txt", "changed\n")
            let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
            #expect(kept.notes == [UndoSkip.unsafeRepository(".git/\(file) is not a plain file").note])
            #expect(scratch.read("target") == original)
        }
    }

    @Test("the folder checks end at the request's deadline: out of time is refused, never waved through")
    func folderChecksUseDeadline() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        #expect(UndoRepository.foldersProblem(root: scratch.path("repo"), deadline: .now + .seconds(10)) == nil)
        #expect(UndoRepository.foldersProblem(root: scratch.path("repo"), deadline: .now - .seconds(1)) != nil)
    }

    @Test("a tracked file deeper than the limit is left out with a note; the rest is kept")
    func deepTrackedFile() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        let deep = (0...UndoLimits.maxDepth).map { _ in "d" }.joined(separator: "/") + "/f.txt"
        try scratch.write("repo/" + deep, "x\n")
        try scratch.git(["add", deep])
        try scratch.git(["commit", "-q", "-m", "deep"])
        try scratch.write("repo/" + deep, "changed\n")
        try scratch.write("repo/a.txt", "changed\n")
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .git)
        #expect(kept.notes == [UndoSkip.tooDeep(levels: UndoLimits.maxDepth).note])
        #expect(kept.tally.files == 1)
    }

    @Test("an untracked file deeper than the limit is left out with a note")
    func deepUntrackedFile() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        let deep = (0...UndoLimits.maxDepth).map { _ in "d" }.joined(separator: "/") + "/f.txt"
        try scratch.write("repo/" + deep, "x\n")
        try scratch.write("repo/top.txt", "x\n")
        let kept = UndoKeeper.keep(request(.gitUntracked, cwd: scratch.path("repo")), in: scratch.store, clones: false)
        #expect(kept.paths == ["top.txt"])
        #expect(kept.notes == [UndoSkip.tooDeep(levels: UndoLimits.maxDepth).note])
    }

    @Test("a changed tracked file with other hard links is not handed to git")
    func hardLinkedTrackedFile() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeRepo()
        try scratch.write("repo/b.txt", "b\n")
        try scratch.git(["add", "b.txt"])
        try scratch.git(["commit", "-q", "-m", "b"])
        try scratch.write("secret.txt", "TOKEN\n")
        try FileManager.default.removeItem(atPath: scratch.path("repo/b.txt"))
        link(scratch.path("secret.txt"), scratch.path("repo/b.txt"))
        try scratch.write("repo/a.txt", "changed\n")
        let kept = UndoKeeper.keep(request(.gitWorkingTree, cwd: scratch.path("repo")), in: scratch.store)
        #expect(kept.kind == .git)
        #expect(kept.notes == [UndoSkip.hardLinked("b.txt").note])
        let stash = try #require(kept.git?.stash)
        #expect(try scratch.git(["cat-file", "blob", stash + ":b.txt"], reading: kept) == "b\n")
    }
}

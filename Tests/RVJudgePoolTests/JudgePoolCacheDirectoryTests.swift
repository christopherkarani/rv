#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVJudgePool

@Suite("Judge pool private model cache")
struct JudgePoolCacheDirectoryTests {
    /// A throwaway home: tests never touch the real `~/.config/rv`.
    func scratch() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-judge-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath().path
    }

    func mode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }

    func base(_ home: String) throws -> (fd: Int32, path: String) {
        try #require(JudgePoolCacheDirectory.openBase(home: home))
    }

    @Test("lives under <home>/.config/rv/cache/judge, owner-only, with an unpredictable name every time")
    func createsPrivateDirectory() throws {
        let home = try scratch()
        let opened = try base(home)
        defer { close(opened.fd) }
        #expect(opened.path == home + "/.config/rv/cache/judge")
        #expect(mode(opened.path).map { $0 & 0o777 } == 0o700)
        let first = try #require(JudgePoolCacheDirectory.create(baseFD: opened.fd, basePath: opened.path))
        let second = try #require(JudgePoolCacheDirectory.create(baseFD: opened.fd, basePath: opened.path))
        defer { JudgePoolCacheDirectory.remove(first); JudgePoolCacheDirectory.remove(second) }
        #expect(first.path != second.path)
        #expect(first.path == opened.path + "/" + first.name)
        #expect(first.name.hasPrefix("rv-judge-"))
        #expect(first.name.dropFirst("rv-judge-".count).count == 32, "128 random bits")
        let info = try #require(mode(first.path))
        #expect(info & S_IFMT == S_IFDIR)
        #expect(info & 0o777 == 0o700)
        #expect(mode(first.path + ".lock").map { $0 & S_IFMT } == S_IFREG)
    }

    @Test("a widened judge directory is narrowed back to 0700 through its descriptor")
    func narrowsJudgeDirectory() throws {
        let home = try scratch()
        try FileManager.default.createDirectory(
            atPath: home + "/.config/rv/cache/judge", withIntermediateDirectories: true)
        #expect(chmod(home + "/.config/rv/cache/judge", 0o755) == 0)
        let opened = try base(home)
        close(opened.fd)
        #expect(mode(opened.path).map { $0 & 0o777 } == 0o700)
    }

    @Test("a link planted at rv, cache or judge is refused, and nothing is created through it")
    func refusesLinkedComponents() throws {
        for component in ["rv", "rv/cache", "rv/cache/judge"] {
            let home = try scratch()
            let outside = try scratch()
            let parent = ((home + "/.config/" + component) as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: home + "/.config/" + component, withDestinationPath: outside)
            #expect(JudgePoolCacheDirectory.openBase(home: home) == nil, "\(component)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty, "\(component)")
        }
    }

    @Test("a group- or world-writable level is refused")
    func refusesWritableByOthers() throws {
        let home = try scratch()
        try FileManager.default.createDirectory(atPath: home + "/.config/rv", withIntermediateDirectories: true)
        #expect(chmod(home + "/.config/rv", 0o777) == 0)
        #expect(JudgePoolCacheDirectory.openBase(home: home) == nil)
    }

    @Test("sweep removes dead supervisors' directories, skips live ones, and never follows a link")
    func sweepsLeftovers() throws {
        let home = try scratch()
        let opened = try base(home)
        defer { close(opened.fd) }
        let current = try #require(JudgePoolCacheDirectory.create(baseFD: opened.fd, basePath: opened.path))
        let live = try #require(JudgePoolCacheDirectory.create(baseFD: opened.fd, basePath: opened.path))
        defer { JudgePoolCacheDirectory.remove(current); JudgePoolCacheDirectory.remove(live) }

        // A dead supervisor: its lock is closed, and its tree holds a nested
        // link (and a read-only directory) pointing outside.
        let dead = try #require(JudgePoolCacheDirectory.create(baseFD: opened.fd, basePath: opened.path))
        close(dead.lockFD)
        close(dead.directoryFD)
        let outside = try scratch()
        let precious = outside + "/keep.txt"
        #expect(FileManager.default.createFile(atPath: precious, contents: Data("x".utf8)))
        try FileManager.default.createDirectory(atPath: dead.path + "/m/n", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dead.path + "/m/n/escape", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: dead.path + "/file", withDestinationPath: precious)
        #expect(chmod(dead.path + "/m", 0o500) == 0)

        // A dead supervisor killed before it wrote a lock, a planted
        // top-level link, an orphan lock, and an unrelated directory.
        try FileManager.default.createDirectory(atPath: opened.path + "/rv-judge-nolock", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: opened.path + "/rv-judge-link", withDestinationPath: outside)
        #expect(FileManager.default.createFile(atPath: opened.path + "/rv-judge-orphan.lock", contents: nil))
        try FileManager.default.createDirectory(atPath: opened.path + "/other", withIntermediateDirectories: false)

        JudgePoolCacheDirectory.sweep(baseFD: opened.fd, keeping: current.name)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: current.path))
        #expect(fm.fileExists(atPath: current.path + ".lock"))
        #expect(fm.fileExists(atPath: live.path), "another live supervisor's directory is left alone")
        #expect(fm.fileExists(atPath: live.path + ".lock"))
        #expect(!fm.fileExists(atPath: dead.path))
        #expect(!fm.fileExists(atPath: dead.path + ".lock"))
        #expect(!fm.fileExists(atPath: opened.path + "/rv-judge-nolock"))
        #expect(mode(opened.path + "/rv-judge-link") == nil)
        #expect(!fm.fileExists(atPath: opened.path + "/rv-judge-orphan.lock"))
        #expect(fm.fileExists(atPath: opened.path + "/other"))
        #expect(fm.fileExists(atPath: precious), "a link's target outside the tree survives")
        #expect(try fm.contentsOfDirectory(atPath: outside) == ["keep.txt"])
    }

    @Test("exit cleanup removes the directory and its lock without following links")
    func removesOwnDirectory() throws {
        let home = try scratch()
        let opened = try base(home)
        defer { close(opened.fd) }
        let prepared = try #require(JudgePoolCacheDirectory.create(baseFD: opened.fd, basePath: opened.path))
        let outside = try scratch()
        #expect(FileManager.default.createFile(atPath: outside + "/keep.txt", contents: Data("x".utf8)))
        try FileManager.default.createDirectory(atPath: prepared.path + "/a/b", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: prepared.path + "/a/b/escape", withDestinationPath: outside)

        JudgePoolCacheDirectory.remove(prepared)
        #expect(mode(prepared.path) == nil)
        #expect(mode(prepared.path + ".lock") == nil)
        #expect(FileManager.default.fileExists(atPath: outside + "/keep.txt"))
    }

    @Test("prepare creates the run directory under the given home and sweeps the rest")
    func prepareUsesHome() throws {
        let home = try scratch()
        let opened = try base(home)
        let stale = try #require(JudgePoolCacheDirectory.create(baseFD: opened.fd, basePath: opened.path))
        close(stale.lockFD)
        close(stale.directoryFD)
        close(opened.fd)

        let path = try #require(JudgePoolCacheDirectory.prepare(home: home))
        defer { JudgePoolCacheDirectory.removeCurrent() }
        #expect(path.hasPrefix(home + "/.config/rv/cache/judge/rv-judge-"))
        #expect(mode(path).map { $0 & 0o777 } == 0o700)
        #expect(mode(stale.path) == nil)
    }

    @Test("the home comes from the password database")
    func passwdHome() throws {
        let home = try #require(JudgePoolCacheDirectory.passwdHome())
        let entry = try #require(getpwuid(geteuid()))
        #expect(home == String(cString: try #require(entry.pointee.pw_dir)))
    }

    @Test("workers are always told to use the supervisor's cache")
    func workerArgumentsCarryCache() {
        let key = ModelKey(engine: "ft", bundle: "/models/laya-ft-v2-coreml")
        let arguments = PosixWorkerSpawner.judgeWorkerArguments(
            slot: .primary, compute: .cpu, key: key, cache: "/Users/u/.config/rv/cache/judge/rv-judge-00")
        #expect(arguments == [
            "--worker", "--compute", "cpu", "--engine", "ft", "--bundle", "/models/laya-ft-v2-coreml",
            "--cache", "/Users/u/.config/rv/cache/judge/rv-judge-00",
        ])
    }
}

@Suite("Worker arguments")
struct WorkerOptionsTests {
    @Test("parse inverts the supervisor's worker arguments")
    func roundTrip() throws {
        let key = ModelKey(engine: "laya", bundle: "/models/laya-multilingual-coreml")
        let arguments = PosixWorkerSpawner.judgeWorkerArguments(
            slot: .hedge, compute: .accelerated, key: key, cache: "/Users/u/.config/rv/cache/judge/rv-judge-00")
        #expect(arguments.first == "--worker")
        let options = try #require(WorkerOptions.parse(Array(arguments.dropFirst())))
        #expect(options == WorkerOptions(
            compute: .accelerated, engine: "laya", bundle: "/models/laya-multilingual-coreml",
            cache: "/Users/u/.config/rv/cache/judge/rv-judge-00"))
    }

    @Test("a worker without --cache, or with a relative one, does not start", arguments: [
        ["--compute", "cpu", "--engine", "ft", "--bundle", "/b"],
        ["--compute", "cpu", "--engine", "ft", "--bundle", "/b", "--cache", "c"],
        ["--compute", "cpu", "--engine", "ft", "--bundle", "/b", "--cache"],
        ["--compute", "gpu", "--engine", "ft", "--bundle", "/b", "--cache", "/c"],
        ["--compute", "cpu", "--engine", "x", "--bundle", "/b", "--cache", "/c"],
        ["--compute", "cpu", "--engine", "ft", "--bundle", "/b", "--cache", "/c", "--extra", "1"],
    ])
    func rejectsIncomplete(arguments: [String]) {
        #expect(WorkerOptions.parse(arguments) == nil)
    }
}

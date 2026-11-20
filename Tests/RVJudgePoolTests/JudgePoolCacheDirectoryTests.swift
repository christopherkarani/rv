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
    func scratch() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-judge-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    @Test("a fresh owner-only directory with an unpredictable name, every time")
    func createsPrivateDirectory() throws {
        let parent = try scratch()
        let first = try #require(JudgePoolCacheDirectory.create(in: parent))
        let second = try #require(JudgePoolCacheDirectory.create(in: parent))
        #expect(first != second)
        let name = (first as NSString).lastPathComponent
        #expect(name.hasPrefix("rv-judge-"))
        #expect(name.dropFirst("rv-judge-".count).count == 32, "128 random bits")
        var info = stat()
        #expect(lstat(first, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(info.st_uid == geteuid())
    }

    @Test("sweep removes earlier supervisors' directories, keeps the current one, never follows a link")
    func sweepsLeftovers() throws {
        let parent = try scratch()
        let current = try #require(JudgePoolCacheDirectory.create(in: parent))
        let stale = try #require(JudgePoolCacheDirectory.create(in: parent))
        let outside = try scratch()
        let precious = outside + "/keep.txt"
        #expect(FileManager.default.createFile(atPath: precious, contents: Data("x".utf8)))
        try FileManager.default.createSymbolicLink(atPath: parent + "/rv-judge-link", withDestinationPath: outside)
        let unrelated = parent + "/other"
        try FileManager.default.createDirectory(atPath: unrelated, withIntermediateDirectories: false)

        JudgePoolCacheDirectory.sweep(in: parent, keeping: current)
        #expect(FileManager.default.fileExists(atPath: current))
        #expect(!FileManager.default.fileExists(atPath: stale))
        #expect(!FileManager.default.fileExists(atPath: parent + "/rv-judge-link"))
        #expect(FileManager.default.fileExists(atPath: precious), "the link's target is untouched")
        #expect(FileManager.default.fileExists(atPath: unrelated))
    }

    @Test("workers are always told to use the supervisor's cache")
    func workerArgumentsCarryCache() {
        let key = ModelKey(engine: "ft", bundle: "/models/laya-ft-v2-coreml")
        let arguments = PosixWorkerSpawner.judgeWorkerArguments(
            slot: .primary, compute: .cpu, key: key, cache: "/private/var/folders/x/T/rv-judge-00")
        #expect(arguments == [
            "--worker", "--compute", "cpu", "--engine", "ft", "--bundle", "/models/laya-ft-v2-coreml",
            "--cache", "/private/var/folders/x/T/rv-judge-00",
        ])
    }

    #if canImport(Darwin)
    @Test("the per-user temporary directory comes from confstr, not the environment")
    func userTemporaryDirectory() throws {
        let path = try #require(JudgePoolCacheDirectory.userTemporaryDirectory())
        #expect(path.hasPrefix("/"))
        #expect(!path.hasSuffix("/"))
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_uid == geteuid())
    }
    #endif
}

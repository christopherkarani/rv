#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing

@testable import RVFileStore

@Suite("JSONLAppendLog")
struct JSONLAppendLogTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-append-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func appendsLineWithNewline() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jsonl")
        try JSONLAppendLog.append(Data(#"{"n":1}"#.utf8), to: url)
        try JSONLAppendLog.append(Data("{\"n\":2}\n".utf8), to: url)
        #expect(try text(url) == "{\"n\":1}\n{\"n\":2}\n")
    }

    @Test func closesTornLineBeforeAppending() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jsonl")
        try Data(#"{"torn":"#.utf8).write(to: url)
        try JSONLAppendLog.append(Data(#"{"n":1}"#.utf8), to: url)
        #expect(try text(url) == "{\"torn\":\n{\"n\":1}\n")
    }

    @Test func refusesSymlinkAtLedgerPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("victim.txt")
        try Data("keep\n".utf8).write(to: victim)
        let url = dir.appendingPathComponent("a.jsonl")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim)
        #expect(throws: JSONLAppendLog.AppendError.failed) {
            try JSONLAppendLog.append(Data("x".utf8), to: url)
        }
        #expect(try text(victim) == "keep\n")
    }

    @Test func refusesNonRegularFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fifo.jsonl")
        #expect(url.path.withCString { mkfifo($0, 0o600) } == 0)
        #expect(throws: JSONLAppendLog.AppendError.failed) {
            try JSONLAppendLog.append(Data("x".utf8), to: url)
        }
        let directory = dir.appendingPathComponent("dir.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(throws: JSONLAppendLog.AppendError.failed) {
            try JSONLAppendLog.append(Data("x".utf8), to: directory)
        }
    }

    @Test func createsFileOwnerOnlyAndDirectory0700() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("rv", isDirectory: true)
        let url = sub.appendingPathComponent("a.jsonl")
        try JSONLAppendLog.append(Data("x".utf8), to: url)
        #expect(try mode(url) == 0o600)
        #expect(try mode(sub) == 0o700)
        #expect(try mode(sub.appendingPathComponent("a.jsonl.lock")) == 0o600)
    }

    @Test func concurrentAppendsProduceWholeLines() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jsonl")
        let count = 64
        let payload = String(repeating: "p", count: 512)
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<count {
                group.addTask {
                    try? JSONLAppendLog.append(Data("{\"n\":\(n),\"p\":\"\(payload)\"}".utf8), to: url, sync: false)
                }
            }
        }
        let lines = try text(url).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == count + 1)
        #expect(lines.last == "")
        let ids = try lines.dropLast().map { line -> Int in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return try #require(object?["n"] as? Int)
        }
        #expect(Set(ids) == Set(0..<count))
    }

    @Test func syncFalseStillAppends() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jsonl")
        try JSONLAppendLog.append(Data("a".utf8), to: url, sync: false)
        try JSONLAppendLog.append(Data("b".utf8), to: url, sync: false)
        #expect(try text(url) == "a\nb\n")
    }

    @Test func withExclusiveLockUsesSidecarAndAllowsReplace() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jsonl")
        try JSONLAppendLog.append(Data("old".utf8), to: url)
        let seen = JSONLAppendLog.withExclusiveLock(at: url) { locked -> Bool in
            // Sidecar is held by us; a second process-level lock attempt on it must fail non-blocking.
            let fd = open(locked.appendingPathExtension("lock").path, O_RDWR | O_CLOEXEC)
            defer { close(fd) }
            return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK
        }
        #expect(seen == true)
        let replaced = JSONLAppendLog.withExclusiveLock(at: url) { locked -> Bool in
            (try? Data("new\n".utf8).write(to: locked, options: .atomic)) != nil
        }
        #expect(replaced == true)
        try JSONLAppendLog.append(Data("more".utf8), to: url)
        #expect(try text(url) == "new\nmore\n")
    }
}

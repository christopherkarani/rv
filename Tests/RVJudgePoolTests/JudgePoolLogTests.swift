#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVJudgePool

@Suite("Judge pool log and spawner process state")
struct JudgePoolLogTests {
    func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-judge-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a FIFO planted at the log path is refused without blocking the supervisor")
    func fifoRefused() throws {
        let path = try scratch().appendingPathComponent("judge.log").path
        #expect(mkfifo(path, 0o600) == 0)
        // Without O_NONBLOCK this open would wait forever for a reader.
        #expect(JudgePoolLog.openLog(at: path) == nil)
    }

    @Test("a FIFO with a reader attached is still refused: only a regular file is a log")
    func fifoWithReaderRefused() throws {
        let path = try scratch().appendingPathComponent("judge.log").path
        #expect(mkfifo(path, 0o600) == 0)
        let reader = open(path, O_RDONLY | O_NONBLOCK)
        #expect(reader >= 0)
        defer { close(reader) }
        #expect(JudgePoolLog.openLog(at: path) == nil)
    }

    @Test("a symlink at the log path is refused")
    func symlinkRefused() throws {
        let directory = try scratch()
        let target = directory.appendingPathComponent("elsewhere").path
        #expect(FileManager.default.createFile(atPath: target, contents: Data()))
        let path = directory.appendingPathComponent("judge.log").path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        #expect(JudgePoolLog.openLog(at: path) == nil)
    }

    @Test("a regular file opens owner-only")
    func regularFileOpens() throws {
        let path = try scratch().appendingPathComponent("judge.log").path
        let fd = try #require(JudgePoolLog.openLog(at: path))
        defer { close(fd) }
        var info = stat()
        #expect(fstat(fd, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test("a failed log write is ignored, never raised")
    func failedWriteIgnored() {
        // FileHandle.write raised an NSException here (EBADF, ENOSPC, EPIPE)
        // and took the supervisor down with it.
        JudgePoolLog.write("line\n", to: -1)
    }

    @Test("creating a spawner leaves the process SIGPIPE disposition alone")
    func spawnerLeavesSigpipe() {
        var before = sigaction()
        var after = sigaction()
        sigaction(SIGPIPE, nil, &before)
        _ = PosixWorkerSpawner(executable: "/bin/true", environment: [:]) { _, _ in [] }
        sigaction(SIGPIPE, nil, &after)
        #expect(Self.handler(before) == Self.handler(after))
    }

    static func handler(_ action: sigaction) -> UInt {
        #if canImport(Darwin)
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
        #else
        unsafeBitCast(action.__sigaction_handler.sa_handler, to: UInt.self)
        #endif
    }
}

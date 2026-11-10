#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import RVService

/// rvd's own log: where stderr lands when launchd hands the daemon
/// /dev/null, so launch failures and degraded transports stay visible.
@Suite(.serialized)
struct RVDLogFileTests {
    @Test func pathFollowsThePlatformLogConvention() {
        #if os(macOS)
        #expect(RVDLogFile.path(home: "/Users/a") == "/Users/a/Library/Logs/rv/rvd.log")
        #else
        #expect(RVDLogFile.path(home: "/home/a") == "/home/a/.local/state/rv/rvd.log")
        #endif
    }

    @Test func openCreatesOwnerOnlyDirectoryAndFileAndAppends() throws {
        let root = try scratchDirectory("create")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Logs/rv/rvd.log").path

        try appendLine("one", to: path, maxBytes: 1024)
        try appendLine("two", to: path, maxBytes: 1024)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "one\ntwo\n")
        #expect(try mode(path) == 0o600)
        #expect(try mode((path as NSString).deletingLastPathComponent) == 0o700)
    }

    @Test func openTightensAnExistingLaxFile() throws {
        let root = try scratchDirectory("lax")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rvd.log").path
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        try appendLine("new", to: path, maxBytes: 1024)

        #expect(try mode(path) == 0o600)
        #expect(try mode(root.path) == 0o700)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "old\nnew\n")
    }

    @Test func openRotatesOnceTheCapIsReached() throws {
        let root = try scratchDirectory("rotate")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rvd.log").path
        let full = String(repeating: "x", count: 63) + "\n"
        try Data(full.utf8).write(to: URL(fileURLWithPath: path))
        try Data("older\n".utf8).write(to: URL(fileURLWithPath: path + ".1"))

        try appendLine("fresh", to: path, maxBytes: 64)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "fresh\n")
        #expect(try String(contentsOfFile: path + ".1", encoding: .utf8) == full)
        #expect(FileManager.default.fileExists(atPath: path + ".2") == false)
    }

    @Test func openKeepsAFileBelowTheCap() throws {
        let root = try scratchDirectory("below")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rvd.log").path
        try Data("short\n".utf8).write(to: URL(fileURLWithPath: path))

        try appendLine("next", to: path, maxBytes: 64)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "short\nnext\n")
        #expect(FileManager.default.fileExists(atPath: path + ".1") == false)
    }

    @Test func openRefusesASymlinkedLogFile() throws {
        let root = try scratchDirectory("symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere").path
        try Data("keep\n".utf8).write(to: URL(fileURLWithPath: target))
        let path = root.appendingPathComponent("rvd.log").path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

        #expect(throws: RVDLogFileError.self) { try RVDLogFile.open(path: path, maxBytes: 1024) }
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep\n")
    }

    @Test func openRefusesASymlinkedLogDirectory() throws {
        let root = try scratchDirectory("symdir")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("rv").path
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: real.path)

        #expect(throws: RVDLogFileError.self) {
            try RVDLogFile.open(path: linked + "/rvd.log", maxBytes: 1024)
        }
        #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("rvd.log").path) == false)
    }

    @Test func discardedMeansDevNullOrClosed() throws {
        let null = rawOpen("/dev/null", O_WRONLY)
        defer { close(null) }
        #expect(RVDLogFile.isDiscarded(null))

        var pair: [Int32] = [0, 0]
        #expect(pipe(&pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        #expect(RVDLogFile.isDiscarded(pair[1]) == false)

        let closed = rawOpen("/dev/null", O_WRONLY)
        close(closed)
        #expect(RVDLogFile.isDiscarded(closed))
    }

    @Test func lineIsTimestampedSingleLineAndBounded() {
        let at = Date(timeIntervalSince1970: 0)
        #expect(RVDLogFile.line("rvd: up", now: at) == "1970-01-01T00:00:00Z rvd: up\n")
        let hostile = RVDLogFile.line("a\nb\r\u{1b}[2Kc" + String(repeating: "z", count: 2_000), now: at)
        #expect(hostile.hasPrefix("1970-01-01T00:00:00Z a b  [2Kc"))
        #expect(hostile.dropLast().contains("\n") == false)
        #expect(hostile.utf8.count <= RVDLogFile.maxLineBytes + 1)
    }

    @Test func describeNamesTheErrorCase() {
        #expect(RVDLogFile.describe(RVDLaunchError.invalidIdleExit) == "invalidIdleExit")
    }

    // MARK: - Process

    #if os(macOS)
    /// launchd starts rvd with stderr on /dev/null. A launch failure must
    /// still land, with its cause, in the owner-only log.
    @Test func rvdWithDiscardedStderrLogsTheLaunchFailureCause() throws {
        let rvd = try #require(findDarwinRVDExecutable(), "rvd binary must be built")
        let home = try scratchDirectory("rvd-fail")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = rvd
        process.arguments = ["--idle-exit-seconds", "0"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 1)
        let log = RVDLogFile.path(home: home.path)
        let text = try String(contentsOfFile: log, encoding: .utf8)
        #expect(text.contains("rvd: launch failed: invalidIdleExit"))
        #expect(try mode(log) == 0o600)
    }

    /// A caller that reads rvd's stderr (a terminal, a test, systemd's
    /// journal) keeps it: nothing is written to the log file.
    @Test func rvdWithReadableStderrLeavesTheLogAlone() throws {
        let rvd = try #require(findDarwinRVDExecutable(), "rvd binary must be built")
        let home = try scratchDirectory("rvd-pipe")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = rvd
        process.arguments = ["--idle-exit-seconds", "0"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(err.contains("rvd: launch failed: invalidIdleExit"))
        #expect(FileManager.default.fileExists(atPath: RVDLogFile.path(home: home.path)) == false)
    }
    #endif
}

private func appendLine(_ text: String, to path: String, maxBytes: Int) throws {
    let fd = try RVDLogFile.open(path: path, maxBytes: maxBytes)
    defer { close(fd) }
    let bytes = Array((text + "\n").utf8)
    #expect(write(fd, bytes, bytes.count) == bytes.count)
}

private func mode(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? Int ?? -1) & 0o777
}

private func scratchDirectory(_ label: String) throws -> URL {
    let token = String(UInt32.random(in: .min ... .max), radix: 16)
    let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("rvlog-\(label)-\(token)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func rawOpen(_ path: String, _ flags: Int32) -> Int32 {
    open(path, flags)
}

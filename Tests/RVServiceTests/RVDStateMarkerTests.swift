#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVService

/// Swift twin of `Sources/rv-c/tests/rvd_state_test.c` for the reader, plus
/// the writers rvd and the setup commands use.
struct RVDStateMarkerTests {
    private static let now: Int64 = 1_800_000_000
    private let directory: URL
    private var marker: String { directory.appendingPathComponent("rv/rvd-state").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-rvd-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func parse(_ text: String) -> RVDStateMarker.State {
        RVDStateMarker.parse(Array(text.utf8), now: Self.now)
    }

    private func put(_ text: String, mode: Int16 = 0o600, at path: String? = nil) throws {
        let path = path ?? marker
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = unlink(path)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private func read(_ path: String? = nil, now: Int64 = RVDStateMarkerTests.now) -> RVDStateMarker.State {
        RVDStateMarker.read(path: path ?? marker, now: now)
    }

    /// Same vectors as `test_parse` in rvd_state_test.c.
    @Test func parsesLikeTheCHook() {
        let now = Self.now
        #expect(parse("armed\n") == .armed)
        #expect(parse("restarting \(now)\n") == .restarting)
        #expect(parse("restarting \(now + 60)\n") == .restarting)
        #expect(parse("restarting \(now + RVDStateMarker.restartWindowSeconds)\n") == .restarting)
        #expect(parse("restarting \(now - 1)\n") == .restartExpired)
        #expect(parse("restarting \(now + RVDStateMarker.restartWindowSeconds + 1)\n") == .restartExpired)
        #expect(parse("restarting 999999999999999999\n") == .restartExpired)
        for invalid in [
            "restarting 9999999999999999999\n", "", "armed", "armed\r\n", "armed\nx", "ARMED\n",
            "restarting 1800000060", "restarting \n", "restarting -1\n", "restarting +1800000060\n",
            "restarting 01800000060\n", "restarting  1800000060\n", "restarting 1800000060 \n",
            "restarting 0x6b49d200\n", "allow\n", "armed\0\n",
        ] {
            #expect(parse(invalid) == .invalid, "\(invalid.debugDescription)")
        }
    }

    @Test func onlyAbsentAndRestartingAllowObserve() {
        #expect(RVDStateMarker.State.absent.allowsObserve)
        #expect(RVDStateMarker.State.restarting.allowsObserve)
        #expect(RVDStateMarker.State.armed.allowsObserve == false)
        #expect(RVDStateMarker.State.restartExpired.allowsObserve == false)
        #expect(RVDStateMarker.State.invalid.allowsObserve == false)
    }

    /// Same file checks as `test_read` in rvd_state_test.c.
    @Test func readRefusesUnsafeFiles() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(read() == .absent)
        #expect(read(directory.appendingPathComponent("missing/rvd-state").path) == .absent)

        try put("armed\n")
        #expect(read() == .armed)
        try put("armed\n", mode: 0o644)
        #expect(read() == .armed)
        try put("restarting 1800000060\n")
        #expect(read() == .restarting)
        try put("restarting 1800000060\n", mode: 0o620)
        #expect(read() == .invalid, "group-writable")
        try put("restarting 1800000060\n", mode: 0o602)
        #expect(read() == .invalid, "world-writable")

        try put("restarting 1800000060\n")
        let link = directory.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: marker)
        #expect(read(link) == .invalid, "symlink")
        _ = unlink(link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/nonexistent/rv-rvd-state")
        #expect(read(link) == .invalid, "dangling symlink is not absence")
        _ = unlink(link)
        #expect(read(directory.path) == .invalid, "directory")

        try put(String(repeating: " ", count: RVDStateMarker.maxBytes + 1))
        #expect(read() == .invalid, "oversized")
        try put("")
        #expect(read() == .invalid, "empty")
        if geteuid() != 0 {
            try put("restarting 1800000060\n", mode: 0o200)
            #expect(read() == .invalid, "unreadable")
        }
    }

    @Test func writersProduceWhatTheHookReads() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // Creates the missing config directory.
        #expect(RVDStateMarker.writeRestarting(path: marker, now: Self.now))
        #expect(read() == .restarting)
        #expect(read(now: Self.now + RVDStateMarker.restartAnnounceSeconds) == .restarting)
        #expect(read(now: Self.now + RVDStateMarker.restartAnnounceSeconds + 1) == .restartExpired)
        var info = stat()
        #expect(lstat(marker, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        #expect(RVDStateMarker.writeArmed(path: marker))
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "armed\n")
        #expect(read() == .armed)

        // No temporaries are left beside the marker.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: (marker as NSString).deletingLastPathComponent)
        #expect(siblings == ["rvd-state"])

        #expect(RVDStateMarker.remove(path: marker))
        #expect(read() == .absent)
        #expect(RVDStateMarker.remove(path: marker), "removing an absent marker succeeds")
    }

    /// A planted symlink or foreign-mode file is replaced, never written through.
    @Test func writeReplacesAPlantedSymlink() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("elsewhere").path
        try put("keep\n", at: target)
        try FileManager.default.createDirectory(
            atPath: (marker as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: marker, withDestinationPath: target)
        #expect(RVDStateMarker.writeArmed(path: marker))
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep\n")
        #expect(read() == .armed)
    }

    /// rvd's tick re-arms a deleted, expired or forged marker, and leaves a
    /// restart that `rv setup` just announced alone.
    @Test func rearmKeepsAPendingRestartOnly() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(RVDStateMarker.rearm(path: marker, now: Self.now))
        #expect(read() == .armed, "deleted marker is re-armed")

        RVDStateMarker.writeRestarting(path: marker, now: Self.now)
        RVDStateMarker.rearm(path: marker, now: Self.now + 10)
        #expect(read() == .restarting, "a due restart is left alone")

        RVDStateMarker.rearm(path: marker, now: Self.now + RVDStateMarker.restartAnnounceSeconds + 1)
        #expect(read() == .armed, "an expired restart is re-armed")

        try put("allow\n")
        RVDStateMarker.rearm(path: marker, now: Self.now)
        #expect(read() == .armed, "garbage is re-armed")
        try put("restarting 1800000060\n", mode: 0o666)
        RVDStateMarker.rearm(path: marker, now: Self.now)
        #expect(read() == .armed, "a world-writable restart is re-armed")
    }

    /// rvd and setup touch the owner's marker only from the owner's HOME.
    @Test func passwdPathRequiresTheLoginHome() throws {
        let path = try #require(RVDStateMarker.passwdPath())
        #expect(path.hasSuffix("/.config/rv/rvd-state"))
        let home = String(path.dropLast("/.config/rv/rvd-state".count))
        #expect(RVDStateMarker.passwdPath(ifHomeIs: home) == path)
        #expect(RVDStateMarker.passwdPath(ifHomeIs: home + "/") == path)
        #expect(RVDStateMarker.passwdPath(ifHomeIs: directory.path) == nil)
        #expect(RVDStateMarker.passwdPath(ifHomeIs: "") == nil)
    }
}

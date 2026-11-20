#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The rvd state marker, `~/.config/rv/rvd-state` under the passwd home.
/// Swift twin of `Sources/rv-c/rvd_state.c` (the reader) plus every writer.
///
/// Observe mode lets a hook step aside when rvd is unreachable. The marker
/// keeps that for a fresh install (no marker) and an announced restart
/// (`restarting <epoch>`, still due), and takes it away once rvd ran and
/// went away unannounced (`armed`): stopping or crashing rvd is then no way
/// around rv. It can only take the step-aside away, never grant anything.
///
/// Writers:
/// - rvd writes `armed` once it serves, and re-arms on a short tick so a
///   marker deleted in one command and a stop in a later one still fail
///   closed. The tick leaves a pending restart alone.
/// - rvd writes `restarting` once it sees its binary replaced (it is about
///   to exit for the upgrade); `rv setup` and `rv service restart` write it
///   before they bounce rvd. The next rvd start re-arms.
/// - `rv uninstall` removes it.
/// - A stop, SIGTERM, SIGKILL or crash writes nothing, so it stays `armed`.
///
/// The agent runs as the same uid, so an opaque command that both stops rvd
/// and rewrites this file still gets through; `RVWiringPaths` covers the
/// path so the file-tool and shell doors refuse the write they can see.
public enum RVDStateMarker {
    public enum State: Equatable, Sendable {
        case absent, restarting, armed, restartExpired, invalid

        /// Observe mode may step aside: rvd never ran here, or a restart
        /// was announced and is still due.
        public var allowsObserve: Bool { self == .absent || self == .restarting }
    }

    /// Same caps as `rvd_state.h`.
    public static let maxBytes = 64
    public static let restartWindowSeconds: Int64 = 120
    /// How long writers announce a restart for (inside the window).
    public static let restartAnnounceSeconds: Int64 = 60
    /// rvd's re-arm tick (the stale-check cadence).
    public static let rearmInterval: TimeInterval = 5

    static let armedText = "armed\n"
    static let restartingPrefix = "restarting "

    /// `<home>/.config/rv/rvd-state`.
    public static func path(home: String) -> String {
        home + "/.config/rv/rvd-state"
    }

    /// The marker under the passwd home (never `$HOME`), as the hook reads it.
    public static func passwdPath() -> String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        guard home.hasPrefix("/") else { return nil }
        return path(home: home)
    }

    /// The passwd-home marker, only when `home` is that same home. rvd and
    /// the setup commands run with an explicit HOME; a test or sandbox HOME
    /// must never arm or disarm the owner's real marker.
    public static func passwdPath(ifHomeIs home: String) -> String? {
        guard let path = passwdPath() else { return nil }
        let passwdHome = String(path.dropLast("/.config/rv/rvd-state".count))
        return standardized(passwdHome) == standardized(home) ? path : nil
    }

    private static func standardized(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    public static func now() -> Int64 { Int64(time(nil)) }

    // MARK: Reading (twin of rv_rvd_state_parse / rv_rvd_state_read)

    public static func parse(_ bytes: [UInt8], now: Int64) -> State {
        if bytes == Array(armedText.utf8) { return .armed }
        let prefix = Array(restartingPrefix.utf8)
        // "restarting " + 1...18 digits (no leading zero) + "\n".
        guard bytes.count >= prefix.count + 2, bytes.count <= prefix.count + 19,
              Array(bytes.prefix(prefix.count)) == prefix,
              bytes.last == UInt8(ascii: "\n"),
              bytes[prefix.count] != UInt8(ascii: "0")
        else { return .invalid }
        var deadline: Int64 = 0
        for byte in bytes[prefix.count..<(bytes.count - 1)] {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return .invalid }
            deadline = deadline * 10 + Int64(byte - UInt8(ascii: "0"))
        }
        guard deadline >= now, deadline <= now + restartWindowSeconds else { return .restartExpired }
        return .restarting
    }

    public static func read(path: String, now: Int64) -> State {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .absent : .invalid }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0,
              info.st_size >= 0, info.st_size <= maxBytes
        else { return .invalid }
        // Read to EOF, one byte past the cap, so a file that grew after
        // fstat is refused rather than parsed from a prefix.
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: maxBytes + 1)
        while true {
            let room = buffer.count - bytes.count
            let n = buffer.withUnsafeMutableBytes { Glue.read(fd, $0.baseAddress, room) }
            if n < 0, errno == EINTR { continue }
            if n < 0 { return .invalid }
            if n == 0 { break }
            bytes += buffer.prefix(n)
            if bytes.count > maxBytes { return .invalid }
        }
        return parse(bytes, now: now)
    }

    // MARK: Writing

    /// rvd is serving: arm unconditionally (an announced restart finished).
    @discardableResult
    public static func writeArmed(path: String) -> Bool {
        write(armedText, to: path)
    }

    /// A restart is about to happen: hooks may step aside until `now + 60`.
    @discardableResult
    public static func writeRestarting(path: String, now: Int64 = RVDStateMarker.now()) -> Bool {
        write("\(restartingPrefix)\(now + restartAnnounceSeconds)\n", to: path)
    }

    /// rvd's tick: re-arm unless the marker already says `armed` or holds a
    /// restart that is still due (`rv setup` may be about to bounce rvd).
    @discardableResult
    public static func rearm(path: String, now: Int64 = RVDStateMarker.now()) -> Bool {
        switch read(path: path, now: now) {
        case .armed, .restarting: return true
        case .absent, .restartExpired, .invalid: return writeArmed(path: path)
        }
    }

    /// `rv uninstall`: rv is gone, so rvd never having run is true again.
    @discardableResult
    public static func remove(path: String) -> Bool {
        unlink(path) == 0 || errno == ENOENT
    }

    /// Atomic replace: a 0600 temporary beside the marker, then rename (which
    /// also replaces a planted symlink or foreign file instead of writing
    /// through it). Creates `~/.config/rv` (0700) if needed.
    private static func write(_ text: String, to path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            guard (try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])) != nil
            else { return false }
        }
        var template = Array((directory + "/.rvd-state.XXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return mkstemp(base)
        }
        guard fd >= 0 else { return false }
        let temporary = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { Glue.write(fd, $0.baseAddress, $0.count) }
        let ok = written == bytes.count && fchmod(fd, 0o600) == 0 && fsync(fd) == 0
        close(fd)
        guard ok, rename(temporary, path) == 0 else {
            unlink(temporary)
            return false
        }
        return true
    }

    /// Unqualified `read`/`write` resolve to the static members above.
    private enum Glue {
        static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
            #if canImport(Darwin)
            Darwin.read(fd, buffer, count)
            #else
            Glibc.read(fd, buffer, count)
            #endif
        }

        static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
            #if canImport(Darwin)
            Darwin.write(fd, buffer, count)
            #else
            Glibc.write(fd, buffer, count)
            #endif
        }
    }
}

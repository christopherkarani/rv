#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import RVPolicy

public enum RVDLogFileError: Error, Sendable, Equatable {
    case directoryUnusable(String)
    case fileUnusable(String)
}

/// rvd's diagnostic log.
///
/// launchd starts rvd with stderr on /dev/null, so a launch failure or a
/// degraded transport used to vanish. When stderr is discarded, rvd points
/// it at an owner-only file instead; a caller that reads stderr (terminal,
/// test, systemd's journal) keeps it.
///
/// Only rvd's own lifecycle lines go here (launch failures, transport
/// warnings). Request handling never writes to stderr, so no command text
/// or secret reaches this file. Growth is bounded by rotating once at
/// startup: at most `maxBytes` per generation, one previous generation.
public enum RVDLogFile {
    public static let maxBytes = 1 << 20
    static let maxLineBytes = 512

    /// macOS: `~/Library/Logs/rv/rvd.log`. Elsewhere: the XDG state default.
    public static func path(home: String) -> String {
        #if os(macOS)
        return home + "/Library/Logs/rv/rvd.log"
        #else
        return home + "/.local/state/rv/rvd.log"
        #endif
    }

    /// Redirects stderr into the log when it is discarded. Returns the log
    /// path when it did; nil when stderr was kept or the log is unusable
    /// (the daemon still runs, just as before).
    @discardableResult
    public static func captureDiscardedStderr() -> String? {
        guard isDiscarded(STDERR_FILENO), let home = HomeDirectory.processValidatedHome() else {
            return nil
        }
        let path = path(home: home)
        guard let fd = try? open(path: path, maxBytes: maxBytes) else { return nil }
        let moved = dup2(fd, STDERR_FILENO) == STDERR_FILENO
        close(fd)
        guard moved else { return nil }
        let pid = getpid()
        FileHandle.standardError.write(Data(line("rvd \(RVDLaunch.versionLine) pid \(pid) started").utf8))
        return path
    }

    /// One timestamped log line: control characters become spaces, so a
    /// message can never forge another line or paint a terminal, and the
    /// whole line is capped at `maxLineBytes`.
    public static func line(_ message: String, now: Date = Date()) -> String {
        let stamp = now.formatted(.iso8601)
        let flat = String(String.UnicodeScalarView(message.unicodeScalars.map {
            $0.value < 0x20 || $0.value == 0x7f ? " " : $0
        }))
        var text = "\(stamp) \(flat)"
        if text.utf8.count > maxLineBytes {
            text = String(decoding: text.utf8.prefix(maxLineBytes), as: UTF8.self)
        }
        return text + "\n"
    }

    /// The error's own description (enum case names for rvd's launch
    /// errors). Launch errors carry no request data.
    public static func describe(_ error: any Error) -> String {
        String(describing: error)
    }

    /// True when `fd` is closed or is /dev/null.
    static func isDiscarded(_ fd: Int32) -> Bool {
        var current = stat()
        guard fstat(fd, &current) == 0 else { return true }
        var null = stat()
        guard stat("/dev/null", &null) == 0 else { return false }
        return current.st_dev == null.st_dev && current.st_ino == null.st_ino
    }

    /// Opens `path` for append, owner-only, after rotating it to `path.1`
    /// once it reaches `maxBytes`. Refuses symlinks and anything not owned
    /// by this user, so the log cannot be aimed at another file.
    static func open(path: String, maxBytes: Int) throws(RVDLogFileError) -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        try prepareDirectory(directory)
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard isRegularFile(existing), existing.st_uid == geteuid() else {
                throw .fileUnusable(path)
            }
            if Int(existing.st_size) >= maxBytes, rename(path, path + ".1") != 0 {
                throw .fileUnusable(path)
            }
        }
        let fd = systemOpen(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .fileUnusable(path) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, isRegularFile(opened), opened.st_uid == geteuid(),
            fchmod(fd, 0o600) == 0
        else {
            close(fd)
            throw .fileUnusable(path)
        }
        return fd
    }

    private static func prepareDirectory(_ directory: String) throws(RVDLogFileError) {
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .directoryUnusable(directory)
        }
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == geteuid(), chmod(directory, 0o700) == 0
        else {
            throw .directoryUnusable(directory)
        }
    }

    private static func isRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
    }
}

/// `open(2)` under a name that cannot collide with `RVDLogFile.open`.
private func systemOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
    open(path, flags, mode)
}

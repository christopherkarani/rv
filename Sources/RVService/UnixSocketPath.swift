#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum UnixSocketPathError: Error, Sendable, Equatable {
    case runtimeDirectoryMissing
    case pathTooLong
    case permission
    /// Linux, XDG_RUNTIME_DIR unset: the uid-derived runtime directory
    /// (`/run/user/<uid>`, carried here) is missing and could not be
    /// created, or is not a directory this user owns that group and others
    /// cannot write.
    case userRuntimeDirectoryUnavailable(String)
}

/// Production socket path: `$XDG_RUNTIME_DIR/rv/evaluate.sock` on Linux,
/// or `/run/user/<uid>/rv/evaluate.sock` when XDG_RUNTIME_DIR is unset
/// (the same rule as every client: the C hook, `clientSocket`, the Python
/// SDK); `$HOME/.config/rv/evaluate.sock` on macOS. An empty base is
/// fail-closed. There is no `/tmp` fallback on either platform.
public enum UnixSocketPath {
    public static let directoryName = "rv"
    public static let socketFileName = "evaluate.sock"
    /// NUL-inclusive `sockaddr_un` path budget: 108 on Linux, 104 on Darwin.
    public static let maxSocketPathBytes: Int = {
        #if os(Linux)
        return 108
        #else
        return 104
        #endif
    }()

    public static func resolve(xdgRuntimeDir: String?) throws -> URL {
        guard let raw = xdgRuntimeDir?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false
        else {
            throw UnixSocketPathError.runtimeDirectoryMissing
        }
        let socket = URL(fileURLWithPath: raw, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(socketFileName)
        guard socket.path.utf8.count + 1 <= maxSocketPathBytes else {
            throw UnixSocketPathError.pathTooLong
        }
        return socket
    }

    /// Production macOS socket path: `$HOME/.config/rv/evaluate.sock`.
    /// Deterministic under launchd agents and login shells alike (unlike
    /// per-session `TMPDIR`). Same fail-closed rules as the Linux resolver.
    public static func resolve(homeDirectory: String?) throws -> URL {
        guard let raw = homeDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false
        else {
            throw UnixSocketPathError.runtimeDirectoryMissing
        }
        let socket = URL(fileURLWithPath: raw, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(socketFileName)
        guard socket.path.utf8.count + 1 <= maxSocketPathBytes else {
            throw UnixSocketPathError.pathTooLong
        }
        return socket
    }

    /// systemd's per-user runtime root: rvd's unit runs with
    /// `XDG_RUNTIME_DIR=/run/user/<uid>`.
    public static let userRuntimeRoot = "/run/user"

    /// The socket a Linux client dials, and whether a connect miss there
    /// proves rvd is absent.
    public struct ClientSocket: Sendable, Equatable {
        public let url: URL
        /// True only for the uid-derived runtime directory. An agent can set
        /// XDG_RUNTIME_DIR through project-scoped host config, so a miss
        /// under any other directory proves nothing about rvd.
        public let isOwnerRuntime: Bool
    }

    /// Mirrors `unix_socket_path` in Sources/rv-c/rv.c:
    /// `$XDG_RUNTIME_DIR/rv/evaluate.sock`, or the uid-derived
    /// `/run/user/<uid>/rv/evaluate.sock` when XDG_RUNTIME_DIR is unset.
    /// `isOwnerRuntime` holds when XDG is unset or exactly the uid-derived
    /// directory. Nil when XDG is set but empty, or the path is too long.
    public static func clientSocket(xdgRuntimeDir: String?, uid: UInt32) -> ClientSocket? {
        let ownerDirectory = "\(userRuntimeRoot)/\(uid)"
        let directory = xdgRuntimeDir ?? ownerDirectory
        guard directory.isEmpty == false, let url = try? resolve(xdgRuntimeDir: directory) else { return nil }
        return ClientSocket(url: url, isOwnerRuntime: directory == ownerDirectory)
    }

    /// The socket rvd binds on Linux: the directory every client dials
    /// (`clientSocket`). XDG_RUNTIME_DIR unset means the uid-derived
    /// `/run/user/<uid>`, so rvd runs without a systemd user manager (no
    /// logind, containers, WSL); set but empty is fail-closed.
    static func serverSocket(
        xdgRuntimeDir: String?,
        uid: UInt32,
        userRuntimeRoot: String = userRuntimeRoot
    ) throws -> URL {
        try resolve(xdgRuntimeDir: xdgRuntimeDir ?? "\(userRuntimeRoot)/\(uid)")
    }

    public static func production(
        environment: [String: String]? = nil
    ) throws -> URL {
        #if os(Linux)
        let xdg = environment.map { $0["XDG_RUNTIME_DIR"] } ?? liveXDGRuntimeDir()
        return try serverSocket(xdgRuntimeDir: xdg, uid: getuid())
        #else
        if let environment {
            return try resolve(homeDirectory: environment["HOME"])
        }
        return try resolve(homeDirectory: liveHomeDirectory())
        #endif
    }

    /// `getenv`, not `ProcessInfo.environment` (Darwin caches the snapshot).
    private static func liveXDGRuntimeDir() -> String? {
        guard let pointer = getenv("XDG_RUNTIME_DIR") else { return nil }
        return String(cString: pointer)
    }

    /// `getenv`, not `ProcessInfo.environment` (Darwin caches the snapshot).
    private static func liveHomeDirectory() -> String? {
        guard let pointer = getenv("HOME") else { return nil }
        return String(cString: pointer)
    }

    /// Prepares the socket's parents, then unlinks a stale socket.
    ///
    /// Only the `rv` directory is RV-owned: it is created at 0700 and always
    /// chmodded back to 0700. The base directory (`$XDG_RUNTIME_DIR`,
    /// `$HOME/.config`) is created at 0700 when missing. A pre-existing base
    /// must be a directory owned by this uid; a group- or world-writable one
    /// is rejected and not chmodded, and any other safe base is tightened to
    /// 0700. The stale entry is unlinked only when it is a socket or a
    /// symlink; anything else fails closed so a directory or user file at the
    /// socket path is never deleted.
    ///
    /// The uid-derived base (`/run/user/<uid>`) is never created with
    /// intermediates: rvd makes only that one directory, as logind would,
    /// and only root may also make a missing `/run/user` (0755). Any
    /// failure there is `userRuntimeDirectoryUnavailable`.
    public static func prepareRuntime(for socketURL: URL) throws {
        try prepareRuntime(for: socketURL, userRuntimeRoot: userRuntimeRoot, uid: getuid())
    }

    static func prepareRuntime(for socketURL: URL, userRuntimeRoot: String, uid: UInt32) throws {
        let rvDir = socketURL.deletingLastPathComponent()
        let baseDir = rvDir.deletingLastPathComponent()
        let ownerRuntime = "\(userRuntimeRoot)/\(uid)"
        if baseDir.path == ownerRuntime {
            do {
                try prepareUserRuntimeDirectory(baseDir, root: userRuntimeRoot, uid: uid)
            } catch {
                throw UnixSocketPathError.userRuntimeDirectoryUnavailable(ownerRuntime)
            }
        } else {
            try prepareBaseDirectory(baseDir)
        }
        try createOwnerOnlyDirectory(rvDir)
        try removeStaleSocket(at: socketURL)
    }

    /// Creates `/run/user/<uid>` (one level, 0700) when missing; root may
    /// also create a missing `/run/user` (0755). Then the base-directory
    /// rules apply as to any other base.
    private static func prepareUserRuntimeDirectory(_ url: URL, root: String, uid: UInt32) throws {
        if lstatKind(url.path) == nil {
            if lstatKind(root) == nil, uid == 0 {
                guard mkdir(root, 0o755) == 0 || errno == EEXIST else { throw UnixSocketPathError.permission }
            }
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw UnixSocketPathError.permission }
        }
        guard lstatKind(url.path) == UInt32(S_IFDIR) else { throw UnixSocketPathError.permission }
        try prepareBaseDirectory(url)
    }

    private static func lstatKind(_ path: String) -> UInt32? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return UInt32(status.st_mode) & UInt32(S_IFMT)
    }

    /// Unlinks `socketURL` when it names a socket. Anything else — including
    /// a missing path — is left alone. Listener teardown only.
    static func removeSocketFileIfSocket(at socketURL: URL) {
        guard fileType(at: socketURL) == .socket else { return }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private enum FileKind {
        case absent
        case socket
        case symlink
        case other
    }

    private static func fileType(at url: URL) -> FileKind {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return .absent }
        let mode = UInt32(status.st_mode)
        if mode & UInt32(S_IFMT) == UInt32(S_IFSOCK) { return .socket }
        if mode & UInt32(S_IFMT) == UInt32(S_IFLNK) { return .symlink }
        return .other
    }

    private static func removeStaleSocket(at socketURL: URL) throws {
        switch fileType(at: socketURL) {
        case .absent:
            return
        case .socket, .symlink:
            try FileManager.default.removeItem(at: socketURL)
        case .other:
            throw UnixSocketPathError.permission
        }
    }

    /// Sets POSIX 0600 on the socket, then throws `permission` if the mode is not owner-only.
    public static func applyOwnerOnlySocketMode(to socketURL: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: socketURL.path
        )
        let mode = try posixMode(of: socketURL)
        guard mode & 0o777 == 0o600 else {
            throw UnixSocketPathError.permission
        }
    }

    /// Returns POSIX permission bits of `url`.
    public static func posixMode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let raw = attrs[.posixPermissions] as? NSNumber else {
            throw UnixSocketPathError.permission
        }
        return raw.intValue
    }

    /// The base directory is shared with the rest of the system. Create it
    /// owner-only when missing. A pre-existing base must be a directory owned
    /// by this uid. Group- or world-writable bases (`mode & 0o022 != 0`) are
    /// the same `permission` error as a foreign owner, and are not chmodded.
    /// Any other pre-existing base is tightened to 0700, same as one we create.
    private static func prepareBaseDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            try createOwnerOnlyDirectory(url)
            return
        }
        guard isDirectory.boolValue else {
            throw UnixSocketPathError.permission
        }
        let owner = try FileManager.default.attributesOfItem(atPath: url.path)[.ownerAccountID]
        guard (owner as? NSNumber)?.uint32Value == geteuid() else {
            throw UnixSocketPathError.permission
        }
        let mode = try posixMode(of: url)
        guard mode & 0o022 == 0 else {
            throw UnixSocketPathError.permission
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        let tightened = try posixMode(of: url)
        guard tightened & 0o777 == 0o700 else {
            throw UnixSocketPathError.permission
        }
    }

    private static func createOwnerOnlyDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        let mode = try posixMode(of: url)
        guard mode & 0o777 == 0o700 else {
            throw UnixSocketPathError.permission
        }
    }
}

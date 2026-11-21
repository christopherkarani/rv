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

    /// The uid-derived runtime directory (`<root>/<uid>`) when rvd would
    /// bind under it (XDG_RUNTIME_DIR unset), nothing is at that path, and
    /// `prepareRuntime` could not create it for `uid`: not root, and the
    /// root missing or not writable by this process. Nil otherwise, so it
    /// names only a start that cannot succeed. `rv setup` asks before it
    /// starts rvd itself.
    public static func uncreatableUserRuntimeDirectory(
        xdgRuntimeDir: String?,
        uid: UInt32,
        userRuntimeRoot: String = userRuntimeRoot
    ) -> String? {
        guard xdgRuntimeDir == nil, uid != 0 else { return nil }
        let directory = "\(userRuntimeRoot)/\(uid)"
        guard lstatKind(directory) == nil else { return nil }
        if lstatKind(userRuntimeRoot) != nil, access(userRuntimeRoot, W_OK | X_OK) == 0 { return nil }
        return directory
    }

    /// The one-line fix for a missing uid-derived runtime directory, shared
    /// by rvd's refusal and by `rv setup`'s (install.sh prints the same).
    /// `install -d -m` sets each mode outright: a `mkdir -p` that also made
    /// the parent would leave it to root's umask (0750 under 027), which
    /// the user cannot search.
    public static func userRuntimeDirectoryFix(directory: String, uid: UInt32) -> String {
        let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
        return "as root, install -d -m 0755 \(parent) && install -d -m 0700 -o \(uid) \(directory); "
            + "or set XDG_RUNTIME_DIR to a directory only you can access, for rvd and for your agents"
    }

    /// Creates `/run/user/<uid>` (one level, 0700) when missing; root may
    /// also create a missing `/run/user` (0755). Then the base-directory
    /// rules apply as to any other base.
    private static func prepareUserRuntimeDirectory(_ url: URL, root: String, uid: UInt32) throws {
        if lstatKind(url.path) == nil {
            if lstatKind(root) == nil, uid == 0 {
                if mkdir(root, 0o755) == 0 {
                    // mkdir's mode passes through the umask: root's 077
                    // would leave /run/user 0700, which no other account
                    // could search for its own directory.
                    guard chmod(root, 0o755) == 0 else { throw UnixSocketPathError.permission }
                } else {
                    guard errno == EEXIST else { throw UnixSocketPathError.permission }
                }
            }
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw UnixSocketPathError.permission }
        }
        guard lstatKind(url.path) == UInt32(S_IFDIR) else { throw UnixSocketPathError.permission }
        try prepareBaseDirectory(url)
    }

    /// Why rvd cannot use the uid-derived runtime directory
    /// (`userRuntimeDirectoryUnavailable`), and what root runs to fix
    /// it. Read from the file system after the failure; it decides
    /// nothing.
    public struct UserRuntimeDirectoryProblem: Sendable, Equatable {
        public let reason: String
        public let fix: String
    }

    public static func userRuntimeDirectoryProblem(
        _ directory: String, userRuntimeRoot root: String = userRuntimeRoot, uid: UInt32 = getuid()
    ) -> UserRuntimeDirectoryProblem {
        let make = "install -d -m 0700 -o \(uid) \(directory)"
        var status = stat()
        guard lstat(directory, &status) == 0 else {
            return unexaminableUserRuntimeDirectoryProblem(directory, userRuntimeRoot: root, uid: uid, error: errno)
        }
        let kind = UInt32(status.st_mode) & UInt32(S_IFMT)
        guard kind == UInt32(S_IFDIR) else {
            let what = kind == UInt32(S_IFLNK) ? "a symbolic link" : "not a directory"
            return UserRuntimeDirectoryProblem(
                reason: "\(directory) is \(what)", fix: "as root, remove \(directory), then \(make)")
        }
        guard UInt32(status.st_uid) == uid else {
            // Not chown in place: whatever the other account put inside
            // would stay, and stay its own.
            return UserRuntimeDirectoryProblem(
                reason: "\(directory) belongs to uid \(status.st_uid), not to this account (uid \(uid))",
                fix: "as root, remove \(directory), then \(make)")
        }
        let fix = "as root, \(make)"
        let mode = UInt32(status.st_mode) & 0o7777
        guard mode & 0o022 == 0 else {
            return UserRuntimeDirectoryProblem(
                reason: "\(directory) has mode 0\(String(mode, radix: 8)), which group or others can write", fix: fix)
        }
        return UserRuntimeDirectoryProblem(reason: "\(directory) could not be prepared", fix: fix)
    }

    /// `lstat(directory)` failed with `error`. Only a missing directory is
    /// "does not exist": EACCES means a directory on the way is not
    /// searchable by this account, and making the runtime directory would
    /// change nothing until it is.
    static func unexaminableUserRuntimeDirectoryProblem(
        _ directory: String, userRuntimeRoot root: String, uid: UInt32, error: Int32
    ) -> UserRuntimeDirectoryProblem {
        let make = "install -d -m 0700 -o \(uid) \(directory)"
        switch error {
        case ENOENT where lstatKind(root) == nil:
            // `install -d -m 0755`, not `mkdir`: root's umask could leave
            // /run/user 0700, which no other account can search.
            return UserRuntimeDirectoryProblem(
                reason: "\(root) does not exist (no login manager made it\(uid == 0 ? ", and rvd could not" : ""))",
                fix: "as root, install -d -m 0755 \(root) && \(make)")
        case ENOENT:
            return UserRuntimeDirectoryProblem(
                reason: "\(directory) does not exist and this account cannot create it in \(root)",
                fix: "as root, \(make)")
        case EACCES:
            let blocked = firstUnsearchableAncestor(of: directory) ?? root
            return UserRuntimeDirectoryProblem(
                reason: "\(blocked) is not searchable by this account (uid \(uid)), so rvd cannot reach \(directory)",
                fix: "as root, chmod go+x \(blocked), then, if \(directory) does not exist, \(make)")
        default:
            return UserRuntimeDirectoryProblem(
                reason: "\(directory) cannot be examined (\(String(cString: strerror(error))))",
                fix: "as root, \(make)")
        }
    }

    /// The first directory from `/` down to `path`'s parent that this
    /// process may not search, or nil when every one is searchable.
    private static func firstUnsearchableAncestor(of path: String) -> String? {
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix += "/\(component)"
            if access(prefix, X_OK) != 0 { return prefix }
        }
        return nil
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

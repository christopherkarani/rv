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
}

/// Production socket path: `$XDG_RUNTIME_DIR/rv/evaluate.sock` on Linux,
/// `$HOME/.config/rv/evaluate.sock` on macOS. Unset or empty base directory
/// is fail-closed. There is no `/tmp` fallback on either platform.
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
        guard socket.path.utf8.count + 1 <= 108 else {
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

    public static func production(
        environment: [String: String]? = nil
    ) throws -> URL {
        #if os(Linux)
        if let environment {
            return try resolve(xdgRuntimeDir: environment["XDG_RUNTIME_DIR"])
        }
        return try resolve(xdgRuntimeDir: liveXDGRuntimeDir())
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

    /// Creates the socket's two parent directories at 0700, then unlinks a stale socket.
    public static func prepareRuntime(for socketURL: URL) throws {
        let rvDir = socketURL.deletingLastPathComponent()
        let xdgDir = rvDir.deletingLastPathComponent()
        try createOwnerOnlyDirectory(xdgDir)
        try createOwnerOnlyDirectory(rvDir)
        let path = socketURL.path
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: socketURL)
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

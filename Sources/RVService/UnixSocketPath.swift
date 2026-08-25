import Foundation

public enum UnixSocketPathError: Error, Sendable, Equatable {
    case runtimeDirectoryMissing
    case pathTooLong
    case permission
}

/// Production Linux socket path: `$XDG_RUNTIME_DIR/rv/evaluate.sock`.
/// Unset or empty `XDG_RUNTIME_DIR` is fail-closed. There is no `/tmp` fallback.
public enum UnixSocketPath {
    public static let directoryName = "rv"
    public static let socketFileName = "evaluate.sock"

    public static func resolve(xdgRuntimeDir: String?) throws -> URL {
        guard let raw = xdgRuntimeDir?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false
        else {
            throw UnixSocketPathError.runtimeDirectoryMissing
        }
        let socket = URL(fileURLWithPath: raw, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(socketFileName)
        let maxPath = 108
        guard socket.path.utf8.count + 1 <= maxPath else {
            throw UnixSocketPathError.pathTooLong
        }
        return socket
    }

    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        try resolve(xdgRuntimeDir: environment["XDG_RUNTIME_DIR"])
    }

    /// Creates `$XDG_RUNTIME_DIR` and `$XDG_RUNTIME_DIR/rv` at 0700, then unlinks a stale socket.
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

    public static func assertSocketMode(_ socketURL: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: socketURL.path
        )
        let mode = try posixMode(socketURL)
        guard mode & 0o777 == 0o600 else {
            throw UnixSocketPathError.permission
        }
    }

    public static func posixMode(_ url: URL) throws -> Int {
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
        let mode = try posixMode(url)
        guard mode & 0o777 == 0o700 else {
            throw UnixSocketPathError.permission
        }
    }
}

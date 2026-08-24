import Darwin
import Foundation

/// Internal. Single owner of owner-only persistence choreography: prepare a
/// 0700 directory, then write atomically through a tmp sibling chmod'd 0600
/// before the rename so the destination is never observable world-readable.
/// Mirrors the "single owner" doctrine of ExclusiveFileLock.
enum SecureFileIO {
    /// Creates `directory` (with intermediates) and re-asserts 0700 on it.
    static func prepareOwnerOnlyDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    /// Writes `body` atomically as an owner-only file: parent directory is
    /// prepared at 0700, tmp sibling written at 0600, renamed into place,
    /// destination mode re-asserted after the swap.
    static func writeAtomicallyOwnerOnly(
        _ body: String,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        try prepareOwnerOnlyDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        let temp = url.appendingPathExtension("tmp")
        do {
            try body.write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            throw SecureFileIOError.writeFailed
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temp.path
            )
            let renamed: Int32 = url.withUnsafeFileSystemRepresentation { dest in
                temp.withUnsafeFileSystemRepresentation { src in
                    guard let dest, let src else { return Int32(-1) }
                    return rename(src, dest)
                }
            }
            if renamed != 0 {
                throw SecureFileIOError.writeFailed
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    enum SecureFileIOError: Error, Equatable {
        case writeFailed
    }
}

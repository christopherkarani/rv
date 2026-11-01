import Foundation

enum FileOpsError: Error, Equatable, Sendable {
    case symbolicLink
}

struct FileOps {
    var fileManager: FileManager

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func fileExists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func readData(_ path: String) -> Data? {
        fileManager.contents(atPath: path)
    }

    func write(_ contents: String, to path: String) throws {
        try createDirectory(atPath: (path as NSString).deletingLastPathComponent)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Atomically replaces a shared user config. When different bytes are
    /// already there, they are first copied to a new timestamped sibling
    /// (`<path>.rv-backup-<UTC>[-n]`) that never overwrites an earlier one.
    /// Returns that backup path, or nil when nothing was replaced.
    @discardableResult
    func writeData(_ data: Data, to path: String) throws -> String? {
        try createDirectory(atPath: (path as NSString).deletingLastPathComponent)
        if isSymbolicLink(path) {
            throw FileOpsError.symbolicLink
        }
        let mode = posixMode(at: path) ?? 0o600
        let backup = try backupSharedConfig(path, replacingWith: data)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return backup
    }

    private func backupSharedConfig(_ path: String, replacingWith data: Data) throws -> String? {
        guard let existing = readData(path), existing != data else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stem = path + ".rv-backup-" + formatter.string(from: Date())
        var backup = stem
        var suffix = 1
        while fileManager.fileExists(atPath: backup) || isSymbolicLink(backup) {
            backup = stem + "-\(suffix)"
            suffix += 1
        }
        try fileManager.copyItem(atPath: path, toPath: backup)
        return backup
    }

    func isSymbolicLink(_ path: String) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func posixMode(at path: String) -> Int? {
        guard let raw = (try? fileManager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber else {
            return nil
        }
        return raw.intValue & 0o777
    }

    func createDirectory(atPath path: String) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func removeFile(atPath path: String) {
        guard fileManager.fileExists(atPath: path) else { return }
        try? fileManager.removeItem(atPath: path)
    }

    func removeDirectoryIfEmpty(atPath path: String) {
        guard isDirectory(path) else { return }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path), contents.isEmpty else {
            return
        }
        try? fileManager.removeItem(atPath: path)
    }

    /// Moves an occupied owned path aside (`path.bak`) so setup can rewrite it.
    /// Symlinks are removed without a backup (nothing useful to restore as bytes).
    func backupAndClearOwnedPath(_ path: String) throws {
        if isSymbolicLink(path) {
            try fileManager.removeItem(atPath: path)
            return
        }
        guard fileManager.fileExists(atPath: path) else { return }
        let backup = path + ".bak"
        if fileManager.fileExists(atPath: backup) {
            try fileManager.removeItem(atPath: backup)
        }
        try fileManager.moveItem(atPath: path, toPath: backup)
    }
}

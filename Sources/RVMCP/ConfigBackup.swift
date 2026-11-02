import Foundation

/// Backups of shared user config files (host settings, hooks, MCP configs)
/// taken before rv replaces them. RVCLI's setup writes and `rv mcp setup`
/// both go through here.
public enum ConfigBackup {
    /// Copies the bytes at `path` to a new `<path>.rv-backup-<UTC>[-n]` sibling
    /// (mode 0600) when they differ from `data`. An earlier backup is never
    /// overwritten.
    ///
    /// With `directory`, the copy goes there instead (created mode 0700,
    /// file named from the flattened `path`). Use it for project-scoped files:
    /// a sibling copy of a gitignored `.mcp.json` would not match its ignore
    /// pattern and could commit credentials the rewrite just removed.
    /// Returns the backup path, or nil when there is nothing to keep.
    public static func preserve(
        _ path: String,
        before data: Data,
        directory: String? = nil,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard let existing = fileManager.contents(atPath: path), existing != data else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var stem = path + ".rv-backup-" + formatter.string(from: Date())
        if let directory {
            do {
                try fileManager.createDirectory(
                    atPath: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw ConfigBackupError.writeFailed(directory)
            }
            let flattened = String(path.replacingOccurrences(of: "/", with: "_").suffix(180))
            stem = directory + "/" + flattened + ".rv-backup-" + formatter.string(from: Date())
        }
        var backup = stem
        var suffix = 1
        while fileManager.fileExists(atPath: backup)
            || (try? fileManager.destinationOfSymbolicLink(atPath: backup)) != nil
        {
            backup = stem + "-\(suffix)"
            suffix += 1
        }
        // Owner-only: host configs can hold credentials `rv mcp import` moved out.
        guard fileManager.createFile(atPath: backup, contents: existing, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigBackupError.writeFailed(backup)
        }
        return backup
    }
}

public enum ConfigBackupError: Error, Sendable, Equatable {
    case writeFailed(String)
}

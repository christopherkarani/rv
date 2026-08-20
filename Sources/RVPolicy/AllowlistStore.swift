import Darwin
import Foundation
import RVDomain

public struct AllowlistStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public var fileURL: URL {
        RVPolicyPaths.allowlistFile(inConfigDir: baseDirectory)
    }

    /// Fail-open load for evaluate. Symlink into `workspacePath` → empty. Invalid TOML → empty.
    public func loadUserSnapshot(workspacePath: String?, now: Date) -> AllowlistSnapshot {
        switch loadForValidate(workspacePath: workspacePath) {
        case .missing, .symlinkIntoWorkspace, .invalid:
            return .empty
        case .ok(let entries):
            return AllowlistSnapshot(entries: entries.filter { $0.isActive(at: now) })
        }
    }

    public enum LoadResult: Equatable, Sendable {
        case missing
        case symlinkIntoWorkspace
        case invalid(AllowlistParseError)
        case ok([AllowlistEntry])
    }

    public func loadForValidate(workspacePath: String?) -> LoadResult {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        if isSymlinkIntoWorkspace(url: url, workspacePath: workspacePath) {
            return .symlinkIntoWorkspace
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return .invalid(.invalidTOML)
        }
        do {
            let entries = try AllowlistTOML.parse(text)
            return .ok(entries)
        } catch let error as AllowlistParseError {
            return .invalid(error)
        } catch {
            return .invalid(.invalidTOML)
        }
    }

    public func add(
        _ entry: AllowlistEntry,
        tty: TTYCapability
    ) throws {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        try mutate { entries in
            entries.append(entry)
        }
    }

    public func remove(
        matching ruleOrCommand: String,
        tty: TTYCapability
    ) throws -> Int {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        let needle = ruleOrCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        var removed = 0
        try mutate { entries in
            let before = entries.count
            entries.removeAll { entry in
                switch entry.selector {
                case .rule(let ruleID):
                    return ruleID.rawValue == needle
                        || displayRuleID(ruleID) == needle
                        || parseAllowlistRuleID(needle) == ruleID
                case .exactCommand(let command):
                    return command.rawValue == needle
                }
            }
            removed = before - entries.count
        }
        return removed
    }

    /// Rewrite the user allowlist file. Callers that mutate must already enforce TTY.
    package func writeAll(_ entries: [AllowlistEntry]) throws {
        try withFileLock {
            try writeAllUnlocked(entries)
        }
    }

    private func mutate(_ body: (inout [AllowlistEntry]) throws -> Void) throws {
        try withFileLock {
            var entries: [AllowlistEntry] = []
            switch loadForValidate(workspacePath: nil) {
            case .missing, .symlinkIntoWorkspace:
                entries = []
            case .invalid(let error):
                throw error
            case .ok(let existing):
                entries = existing
            }
            try body(&entries)
            try writeAllUnlocked(entries)
        }
    }

    private func writeAllUnlocked(_ entries: [AllowlistEntry]) throws {
        try prepareDirectory()
        let body = AllowlistTOML.render(entries)
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try prepareDirectory()
        let lockURL = RVPolicyPaths.allowlistLockFile(inConfigDir: baseDirectory)
        if FileManager.default.fileExists(atPath: lockURL.path) == false {
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lockURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false
        else {
            throw AllowOnceError.lockFailed
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: lockURL.path
        )
        let fd = lockURL.path.withCString { path in
            open(path, O_RDWR)
        }
        guard fd >= 0 else { throw AllowOnceError.lockFailed }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AllowOnceError.lockFailed }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: baseDirectory.path
        )
    }

    private func isSymlinkIntoWorkspace(url: URL, workspacePath: String?) -> Bool {
        guard let workspacePath, workspacePath.isEmpty == false else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        let parentValues = try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.isSymbolicLinkKey])
        let isLink = (values?.isSymbolicLink == true) || (parentValues?.isSymbolicLink == true)
        guard isLink else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let workspace = URL(fileURLWithPath: workspacePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        if resolved == workspace { return true }
        let prefix = workspace.hasSuffix("/") ? workspace : workspace + "/"
        return resolved.hasPrefix(prefix)
    }
}

import Foundation
import RVDomain

public struct DenylistStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public var fileURL: URL {
        RVPolicyPaths.denylistFile(inConfigDir: baseDirectory)
    }

    public func loadSnapshot() -> DenylistSnapshot {
        switch load() {
        case .missing, .invalid:
            return .empty
        case .ok(let entries):
            return DenylistSnapshot(entries: entries)
        }
    }

    public enum LoadResult: Equatable, Sendable {
        case missing
        case invalid
        case ok([DenylistEntry])
    }

    public func load() -> LoadResult {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return .invalid
        }
        do {
            return .ok(try DenylistTOML.parse(text))
        } catch {
            return .invalid
        }
    }

    /// Dashboard Always-block. No TTY. The preview confirm is the human.
    package func pin(_ entry: DenylistEntry) throws {
        try mutate { entries in
            if entries.contains(where: { $0.matchingView == entry.matchingView }) {
                return
            }
            entries.append(entry)
        }
    }

    private func mutate(_ body: (inout [DenylistEntry]) throws -> Void) throws {
        try withFileLock {
            var entries: [DenylistEntry] = []
            switch load() {
            case .missing:
                entries = []
            case .invalid:
                throw DenylistParseError.invalidTOML
            case .ok(let existing):
                entries = existing
            }
            try body(&entries)
            try writeAllUnlocked(entries)
        }
    }

    private func writeAllUnlocked(_ entries: [DenylistEntry]) throws {
        try prepareDirectory()
        let body = DenylistTOML.render(entries)
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try prepareDirectory()
        do {
            return try ExclusiveFileLock.withLock(
                at: RVPolicyPaths.denylistLockFile(inConfigDir: baseDirectory),
                body
            )
        } catch let error as ExclusiveFileLock.LockError {
            switch error {
            case .lockFailed:
                throw AllowlistStoreError.lockFailed
            }
        }
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
}

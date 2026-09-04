#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

public enum TypedRuleStoreError: Error, Sendable, Equatable {
    case lockFailed
    case invalidFile
}

/// Load/save/merge for compiled typed rules. I/O lives here; matching stays in Domain.
public struct TypedRuleStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public var machineFileURL: URL {
        baseDirectory.appendingPathComponent("typed-rules.json", isDirectory: false)
    }

    public func loadMachine() throws -> [TypedRule] {
        try load(from: machineFileURL, origin: .machine)
    }

    public func saveMachine(_ rules: [TypedRule]) throws {
        try save(rules, to: machineFileURL, origin: .machine, lockURL: machineLockURL)
    }

    public static func repoFileURL(workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".rv", isDirectory: true)
            .appendingPathComponent("typed-rules.json", isDirectory: false)
    }

    public func loadRepo(workspace: URL) throws -> [TypedRule] {
        try load(from: Self.repoFileURL(workspace: workspace), origin: .repo)
    }

    public func saveRepo(_ rules: [TypedRule], workspace: URL) throws {
        let file = Self.repoFileURL(workspace: workspace)
        let lock = file.deletingLastPathComponent()
            .appendingPathComponent(".typed-rules.lock", isDirectory: false)
        try save(rules, to: file, origin: .repo, lockURL: lock)
    }

    public func loadEffective(builtin: [TypedRule], workspace: URL?) throws -> [TypedRule] {
        let machine = try loadMachine()
        let repo: [TypedRule]
        if let workspace {
            repo = try loadRepo(workspace: workspace)
        } else {
            repo = []
        }
        return Self.merge(builtin: builtin, machine: machine, repo: repo)
    }

    /// Restrict-only: later layers may tighten, never drop an earlier deny or ask.
    public static func merge(
        builtin: [TypedRule],
        machine: [TypedRule],
        repo: [TypedRule]
    ) -> [TypedRule] {
        var merged: [TypedRule] = []
        overlay(&merged, builtin, origin: .builtin)
        overlay(&merged, machine, origin: .machine)
        overlay(&merged, repo, origin: .repo)
        return merged
    }

    private static func overlay(
        _ merged: inout [TypedRule],
        _ incoming: [TypedRule],
        origin: TypedRuleOrigin
    ) {
        for rule in incoming {
            let stamped = TypedRule(
                id: rule.id,
                predicate: rule.predicate,
                verdict: rule.verdict,
                origin: origin
            )
            if let index = merged.firstIndex(where: { $0.predicate == stamped.predicate }) {
                if restrictionRank(stamped.verdict) > restrictionRank(merged[index].verdict) {
                    merged[index] = stamped
                }
            } else {
                merged.append(stamped)
            }
        }
    }

    private static func restrictionRank(_ verdict: TypedRuleVerdict) -> Int {
        switch verdict {
        case .allow:
            0
        case .ask:
            1
        case .deny:
            2
        }
    }

    private var machineLockURL: URL {
        baseDirectory.appendingPathComponent(".typed-rules.lock", isDirectory: false)
    }

    private func load(from url: URL, origin: TypedRuleOrigin) throws -> [TypedRule] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        guard let data = try? Data(contentsOf: url) else {
            throw TypedRuleStoreError.invalidFile
        }
        let document: TypedRulesDocument
        do {
            document = try JSONDecoder().decode(TypedRulesDocument.self, from: data)
        } catch {
            throw TypedRuleStoreError.invalidFile
        }
        return document.rules.map { rule in
            TypedRule(
                id: rule.id,
                predicate: rule.predicate,
                verdict: rule.verdict,
                origin: origin
            )
        }
    }

    private func save(
        _ rules: [TypedRule],
        to url: URL,
        origin: TypedRuleOrigin,
        lockURL: URL
    ) throws {
        let stamped = rules.map { rule in
            TypedRule(
                id: rule.id,
                predicate: rule.predicate,
                verdict: rule.verdict,
                origin: origin
            )
        }
        try withFileLock(at: lockURL) {
            try prepareDirectory(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            do {
                data = try encoder.encode(TypedRulesDocument(rules: stamped))
            } catch {
                throw TypedRuleStoreError.invalidFile
            }
            let temp = url.appendingPathExtension("tmp")
            do {
                try data.write(to: temp, options: .atomic)
            } catch {
                throw TypedRuleStoreError.invalidFile
            }
            try setOwnerOnlyFile(temp)
            let renamed: Int32 = url.withUnsafeFileSystemRepresentation { dest in
                temp.withUnsafeFileSystemRepresentation { src in
                    guard let dest, let src else { return Int32(-1) }
                    return rename(src, dest)
                }
            }
            if renamed != 0 {
                throw TypedRuleStoreError.invalidFile
            }
            try setOwnerOnlyFile(url)
        }
    }

    private func withFileLock<T>(at lockURL: URL, _ body: () throws -> T) throws -> T {
        try prepareDirectory(lockURL.deletingLastPathComponent())
        do {
            return try ExclusiveFileLock.withLock(at: lockURL, body)
        } catch let error as ExclusiveFileLock.LockError {
            switch error {
            case .lockFailed:
                throw TypedRuleStoreError.lockFailed
            }
        }
    }

    private func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func setOwnerOnlyFile(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private struct TypedRulesDocument: Codable, Sendable, Equatable {
    var rules: [TypedRule]
}

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
        RVPolicyPaths.policyFile(inConfigDir: baseDirectory)
    }

    public var machineLegacyJSONURL: URL {
        RVPolicyPaths.typedRulesFile(inConfigDir: baseDirectory)
    }

    public func loadMachine() throws -> [TypedRule] {
        try loadDocument(toml: machineFileURL, json: machineLegacyJSONURL)
            .typedRules(origin: .machine)
    }

    public func loadMachineDocument() throws -> PolicyDocument {
        try loadDocument(toml: machineFileURL, json: machineLegacyJSONURL)
    }

    public func saveMachine(_ rules: [TypedRule]) throws {
        let existing = (try? loadMachineDocument()) ?? PolicyDocument()
        try saveMachine(
            PolicyDocument(
                schemaVersion: existing.schemaVersion,
                rules: rules.map { rule in
                    PolicyDocumentRule(
                        id: rule.id,
                        verdict: rule.verdict,
                        predicate: rule.predicate
                    )
                },
                safetyLevel: existing.safetyLevel,
                allowPaths: existing.allowPaths
            )
        )
    }

    public func saveMachine(_ document: PolicyDocument) throws {
        try save(document, to: machineFileURL, lockURL: machineLockURL)
    }

    public static func repoFileURL(workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".rv", isDirectory: true)
            .appendingPathComponent("policy.toml", isDirectory: false)
    }

    public static func repoLegacyJSONURL(workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".rv", isDirectory: true)
            .appendingPathComponent("typed-rules.json", isDirectory: false)
    }

    public func loadRepo(workspace: URL) throws -> [TypedRule] {
        try loadRepoDocument(workspace: workspace).typedRules(origin: .repo)
    }

    public func loadRepoDocument(workspace: URL) throws -> PolicyDocument {
        try loadDocument(
            toml: Self.repoFileURL(workspace: workspace),
            json: Self.repoLegacyJSONURL(workspace: workspace)
        )
    }

    public func saveRepo(_ rules: [TypedRule], workspace: URL) throws {
        let existing = (try? loadRepoDocument(workspace: workspace)) ?? PolicyDocument()
        try saveRepo(
            PolicyDocument(
                schemaVersion: existing.schemaVersion,
                rules: rules.map { rule in
                    PolicyDocumentRule(
                        id: rule.id,
                        verdict: rule.verdict,
                        predicate: rule.predicate
                    )
                },
                safetyLevel: existing.safetyLevel,
                allowPaths: existing.allowPaths
            ),
            workspace: workspace
        )
    }

    public func saveRepo(_ document: PolicyDocument, workspace: URL) throws {
        let file = Self.repoFileURL(workspace: workspace)
        let lock = file.deletingLastPathComponent()
            .appendingPathComponent(".policy.lock", isDirectory: false)
        try save(document, to: file, lockURL: lock)
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
        RVPolicyPaths.policyLockFile(inConfigDir: baseDirectory)
    }

    private func loadDocument(
        toml: URL,
        json: URL
    ) throws -> PolicyDocument {
        if FileManager.default.fileExists(atPath: toml.path) {
            guard let text = try? String(contentsOf: toml, encoding: .utf8) else {
                throw TypedRuleStoreError.invalidFile
            }
            do {
                return try PolicyDocumentTOML.parse(text)
            } catch {
                throw TypedRuleStoreError.invalidFile
            }
        }
        return try loadLegacyJSON(from: json)
    }

    private func loadLegacyJSON(from url: URL) throws -> PolicyDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PolicyDocument()
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
        guard document.schemaVersion == TypedRulesDocument.currentSchemaVersion else {
            throw TypedRuleStoreError.invalidFile
        }
        return PolicyDocument(
            rules: document.rules.map { rule in
                PolicyDocumentRule(
                    id: rule.id,
                    verdict: rule.verdict,
                    predicate: rule.predicate
                )
            }
        )
    }

    private func save(
        _ document: PolicyDocument,
        to url: URL,
        lockURL: URL
    ) throws {
        try withFileLock(at: lockURL) {
            try prepareDirectory(url.deletingLastPathComponent())
            let text = PolicyDocumentTOML.render(document)
            guard let data = text.data(using: .utf8) else {
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
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var rules: [TypedRule]
}

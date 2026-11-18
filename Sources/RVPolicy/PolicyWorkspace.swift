import Foundation
import RVDomain

public enum PolicyDocumentLayer: Sendable, Equatable {
    case machine
    case repo
}

public enum PolicyWorkspaceError: Error, Sendable, Equatable {
    case missingLayer(PolicyDocumentLayer)
}

/// Session that owns machine (`~/.config/rv` or a config dir) and optional repo policy documents.
///
/// Missing files are empty. Nil HOME skips the machine layer and still loads repo, matching
/// `GatedEvaluate.loadTypedRules`. Writes need an explicit layer root.
public struct PolicyWorkspace: Sendable {
    public struct ShowSnapshot: Equatable, Sendable, Codable {
        public var builtin: [TypedRule]
        public var machine: [TypedRule]
        public var repo: [TypedRule]

        public init(
            builtin: [TypedRule] = [],
            machine: [TypedRule] = [],
            repo: [TypedRule] = []
        ) {
            self.builtin = builtin
            self.machine = machine
            self.repo = repo
        }
    }

    public var home: HomeDirectory?
    public var workspace: URL?
    private var configDirectoryOverride: URL?

    public init(home: HomeDirectory?, workspace: URL? = nil) {
        self.home = home
        self.workspace = workspace
        self.configDirectoryOverride = nil
    }

    /// Pin persist and other callers that already have `$HOME/.config/rv` (or a test dir).
    public init(configDirectory: URL, workspace: URL? = nil) {
        self.home = nil
        self.workspace = workspace
        self.configDirectoryOverride = configDirectory
    }

    public func loadMachineDocument() throws -> PolicyDocument {
        guard let directory = machineDirectory else {
            return PolicyDocument()
        }
        return try TypedRuleStore(baseDirectory: directory).loadMachineDocument()
    }

    public func loadRepoDocument() throws -> PolicyDocument {
        guard let workspace else {
            return PolicyDocument()
        }
        return try repoStore(workspace: workspace).loadRepoDocument(workspace: workspace)
    }

    public func loadLayers(builtin: [TypedRule] = []) throws -> ShowSnapshot {
        ShowSnapshot(
            builtin: builtin,
            machine: try loadMachineDocument().typedRules(origin: .machine),
            repo: try loadRepoDocument().typedRules(origin: .repo)
        )
    }

    /// Merged typed rules. The owner's policy ceiling goes last as a
    /// restrict-only overlay, so its deny and ask rules hold whatever the
    /// layers say, at O(rules) per action. An unreadable or invalid ceiling
    /// throws `PolicyCeilingError.invalidFile`, so the door fails closed as
    /// for an invalid `policy.toml`.
    public func loadEffectiveRules(builtin: [TypedRule] = []) throws -> [TypedRule] {
        let machine = try loadMachineDocument()
        let repo = try loadRepoDocument()
        let ceiling = try loadCeiling()
        return TypedRuleStore.merge(
            builtin: builtin,
            machine: machine.typedRules(origin: .machine),
            repo: repo.typedRules(origin: .repo),
            ceiling: ceiling?.typedRules ?? []
        )
    }

    /// Replaces the owner's ceiling. Under the machine policy locks, the
    /// live machine layer is re-checked against the new ceiling (a layer
    /// that asks where it denies is refused with the witness), then
    /// `ceiling.toml` is written and one revision line appended. Callers
    /// confirm the device owner first, as for a machine `policy.toml` save.
    public func replaceCeiling(_ ceiling: PolicyCeiling) throws {
        guard let directory = machineDirectory else {
            throw PolicyWorkspaceError.missingLayer(.machine)
        }
        try TypedRuleStore(baseDirectory: directory).withMachineLocked { machine in
            try ceiling.requireContained(machine)
            try PolicyCeilingStore(configDirectory: directory).commitLocked(ceiling, recordedAt: Date())
        }
    }

    /// The owner's ceiling, or nil when none is set or there is no machine
    /// directory to hold one. Throws `PolicyCeilingError.invalidFile` for a
    /// ceiling file that exists but does not parse.
    public func loadCeiling() throws -> PolicyCeiling? {
        guard let directory = machineDirectory else { return nil }
        return try PolicyCeilingStore(configDirectory: directory).load()
    }

    /// Machine + repo **document** fields only. Does not read `config.json`.
    public func documentSafetyLevel() -> SafetyLevel? {
        let machine = (try? loadMachineDocument())?.safetyLevel
        let repo = (try? loadRepoDocument())?.safetyLevel
        if machine == .strict || repo == .strict {
            return .strict
        }
        if machine == .normal || repo == .normal {
            return .normal
        }
        return nil
    }

    /// Machine + repo **document** `secret.allow_paths` only. Does not read `config.json`.
    public func documentAllowPaths() -> SecretAllowPathSet {
        let machine = (try? loadMachineDocument())?.allowPaths ?? []
        let repo = (try? loadRepoDocument())?.allowPaths ?? []
        return SecretAllowPaths.merge(machine: machine, repo: repo)
    }

    /// Revision log for one layer, oldest first. Missing log is empty.
    public func listRevisions(layer: PolicyDocumentLayer) throws -> [PolicyRevision] {
        switch layer {
        case .machine:
            guard let directory = machineDirectory else {
                throw PolicyWorkspaceError.missingLayer(.machine)
            }
            return try TypedRuleStore(baseDirectory: directory).listMachineRevisions()
        case .repo:
            guard let workspace else {
                throw PolicyWorkspaceError.missingLayer(.repo)
            }
            return try revisionRepoStore(workspace: workspace)
                .listRepoRevisions(workspace: workspace)
        }
    }

    /// Rollback re-submits an earlier revision's document as a new head.
    /// The log is append-only: earlier lines are never rewritten. Restores
    /// that drop a live deny or ask, relax a surviving predicate's verdict,
    /// downgrade the safety level, or widen secret exemptions refuse with
    /// `blockedByFindings` before anything is written. Dropping an allow
    /// still succeeds. The gate compares the live policy file.
    public func rollback(layer: PolicyDocumentLayer, to revision: Int) throws -> PolicyRevision {
        switch layer {
        case .machine:
            guard let directory = machineDirectory else {
                throw PolicyWorkspaceError.missingLayer(.machine)
            }
            return try TypedRuleStore(baseDirectory: directory).rollbackMachine(to: revision)
        case .repo:
            guard let workspace else {
                throw PolicyWorkspaceError.missingLayer(.repo)
            }
            return try revisionRepoStore(workspace: workspace)
                .rollbackRepo(to: revision, workspace: workspace)
        }
    }

    public func upsert(_ rule: PolicyDocumentRule, layer: PolicyDocumentLayer) throws {
        _ = try mergeIncoming(PolicyDocument(rules: [rule]), layer: layer, save: true)
    }

    /// Merges `incoming` rules into the layer. With `save`, the load, merge,
    /// and write run under the store's save locks, so concurrent merges on
    /// one layer serialize and none is lost.
    public func mergeIncoming(
        _ incoming: PolicyDocument,
        layer: PolicyDocumentLayer,
        save: Bool
    ) throws -> PolicyDocument {
        let merge = { (existing: PolicyDocument) -> PolicyDocument in
            var merged = existing
            merged.rules = PolicyDocumentTOML.mergeLayer(
                existing: existing.rules,
                incoming: incoming.rules
            )
            return merged
        }
        guard save else {
            return merge(try loadWritableDocument(layer))
        }
        // A save that would leave the layer asking where the ceiling denies
        // writes nothing. The ceiling is read under the save lock, so a
        // machine save serializes with `replaceCeiling`.
        return try updateDocument(layer: layer) { existing in
            let merged = merge(existing)
            try loadCeiling()?.requireContained(merged)
            return merged
        }
    }

    private var machineDirectory: URL? {
        configDirectoryOverride ?? home.map(RVPolicyPaths.configDirectory(home:))
    }

    private func repoStore(workspace: URL) -> TypedRuleStore {
        TypedRuleStore(baseDirectory: machineDirectory ?? workspace)
    }

    /// Store for repo revision-log operations. The repo log's only
    /// integrity beyond its unkeyed hashes is its location in the machine
    /// config directory, outside the workspace a caged writer controls.
    /// Without a machine directory the fallback would place
    /// `repo-revisions-*.jsonl` inside that workspace, where rollback
    /// targets are forgeable by construction — refuse instead. Plain
    /// document reads keep the `repoStore` fallback: they never touch
    /// the log.
    private func revisionRepoStore(workspace: URL) throws -> TypedRuleStore {
        guard let directory = machineDirectory else {
            throw PolicyWorkspaceError.missingLayer(.machine)
        }
        return TypedRuleStore(baseDirectory: directory)
    }

    private func loadWritableDocument(_ layer: PolicyDocumentLayer) throws -> PolicyDocument {
        switch layer {
        case .machine:
            guard machineDirectory != nil else {
                throw PolicyWorkspaceError.missingLayer(.machine)
            }
            return try loadMachineDocument()
        case .repo:
            guard workspace != nil else {
                throw PolicyWorkspaceError.missingLayer(.repo)
            }
            return try loadRepoDocument()
        }
    }

    private func updateDocument(
        layer: PolicyDocumentLayer,
        _ transform: (PolicyDocument) throws -> PolicyDocument
    ) throws -> PolicyDocument {
        switch layer {
        case .machine:
            guard let directory = machineDirectory else {
                throw PolicyWorkspaceError.missingLayer(.machine)
            }
            return try TypedRuleStore(baseDirectory: directory).updateMachine(transform)
        case .repo:
            guard let workspace else {
                throw PolicyWorkspaceError.missingLayer(.repo)
            }
            return try revisionRepoStore(workspace: workspace)
                .updateRepo(workspace: workspace, transform)
        }
    }
}

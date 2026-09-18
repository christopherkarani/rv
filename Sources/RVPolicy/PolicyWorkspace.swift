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

    public func loadEffectiveRules(builtin: [TypedRule] = []) throws -> [TypedRule] {
        if let directory = machineDirectory {
            return try TypedRuleStore(baseDirectory: directory)
                .loadEffective(builtin: builtin, workspace: workspace)
        }
        let repo: [TypedRule]
        if let workspace {
            repo = try TypedRuleStore(baseDirectory: workspace).loadRepo(workspace: workspace)
        } else {
            repo = []
        }
        return TypedRuleStore.merge(builtin: builtin, machine: [], repo: repo)
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

    public func upsert(_ rule: PolicyDocumentRule, layer: PolicyDocumentLayer) throws {
        _ = try mergeIncoming(PolicyDocument(rules: [rule]), layer: layer, save: true)
    }

    public func mergeIncoming(
        _ incoming: PolicyDocument,
        layer: PolicyDocumentLayer,
        save: Bool
    ) throws -> PolicyDocument {
        var existing = try loadWritableDocument(layer)
        existing.rules = PolicyDocumentTOML.mergeLayer(
            existing: existing.rules,
            incoming: incoming.rules
        )
        if save {
            try saveDocument(existing, layer: layer)
        }
        return existing
    }

    private var machineDirectory: URL? {
        configDirectoryOverride ?? home.map(RVPolicyPaths.configDirectory(home:))
    }

    private func repoStore(workspace: URL) -> TypedRuleStore {
        TypedRuleStore(baseDirectory: machineDirectory ?? workspace)
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

    private func saveDocument(_ document: PolicyDocument, layer: PolicyDocumentLayer) throws {
        switch layer {
        case .machine:
            guard let directory = machineDirectory else {
                throw PolicyWorkspaceError.missingLayer(.machine)
            }
            try TypedRuleStore(baseDirectory: directory).saveMachine(document)
        case .repo:
            guard let workspace else {
                throw PolicyWorkspaceError.missingLayer(.repo)
            }
            try repoStore(workspace: workspace).saveRepo(document, workspace: workspace)
        }
    }
}

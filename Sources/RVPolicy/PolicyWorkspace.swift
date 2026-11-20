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
        try loadEffective(builtin: builtin).rules
    }

    /// One step of `loadEffective`, in the order it runs.
    enum LoadStep {
        case machine, repo, ceiling
    }

    /// The documents `loadEffectiveRules` reads and the rules it merges.
    struct EffectiveLoad {
        var machine: PolicyDocument
        var repo: PolicyDocument
        var ceiling: PolicyCeiling?
        var rules: [TypedRule]
    }

    /// The only typed-policy load: evaluation (via `loadEffectiveRules`) and
    /// `loadStatus` both run it. `entering` names each step before it runs,
    /// so a throw belongs to the last step named.
    func loadEffective(
        builtin: [TypedRule] = [],
        entering: (LoadStep) -> Void = { _ in }
    ) throws -> EffectiveLoad {
        entering(.machine)
        let machine = try loadMachineDocument()
        entering(.repo)
        let repo = try loadRepoDocument()
        entering(.ceiling)
        let ceiling = try loadCeiling()
        let rules = TypedRuleStore.merge(
            builtin: builtin,
            machine: machine.typedRules(origin: .machine),
            repo: repo.typedRules(origin: .repo),
            ceiling: ceiling?.typedRules ?? []
        )
        return EffectiveLoad(machine: machine, repo: repo, ceiling: ceiling, rules: rules)
    }

    /// Why the step that failed refused its file, by the same reader. Run
    /// only after a failure, so a file changed in between can read as nil.
    private func problem(at step: LoadStep) -> PolicyLoadStatus.Problem? {
        switch step {
        case .machine:
            return machineDirectory.flatMap { TypedRuleStore(baseDirectory: $0).machineDocumentProblem() }
        case .repo:
            return workspace.flatMap { repoStore(workspace: $0).repoDocumentProblem(workspace: $0) }
        case .ceiling:
            return machineDirectory.flatMap { PolicyCeilingStore(configDirectory: $0).problem() }
        }
    }

    /// What evaluation loads here right now, from the same `loadEffective`.
    /// Reads only; takes no lock and never consults the revision log
    /// (evaluation does not either). A failed load is reported, never
    /// replaced by an earlier policy: evaluation fails closed on it.
    public func loadStatus() -> PolicyLoadStatus {
        var step = LoadStep.machine
        let location = (configDirectory: machineDirectory?.path, workspace: workspace?.path)
        let load: EffectiveLoad
        do {
            load = try loadEffective { step = $0 }
        } catch {
            let failure: PolicyLoadStatus.Failure = switch step {
            case .machine: .machineInvalid
            case .repo: .repoInvalid
            case .ceiling: .ceilingInvalid
            }
            return PolicyLoadStatus(
                state: .failed, failure: failure, problem: problem(at: step),
                configDirectory: location.configDirectory, workspace: location.workspace)
        }
        func layer(_ document: PolicyDocument) -> PolicyLoadStatus.Layer {
            PolicyLoadStatus.Layer(
                hash: PolicyRevisionIdentity.hash(document),
                ruleCount: document.rules.count,
                exceedsCeiling: load.ceiling.map { $0.check(document).isContained == false } ?? false)
        }
        return PolicyLoadStatus(
            state: .loaded,
            machine: machineDirectory == nil ? nil : layer(load.machine),
            repo: workspace == nil ? nil : layer(load.repo),
            ceilingRuleCount: load.ceiling?.rules.count,
            effectiveRuleCount: load.rules.count,
            configDirectory: location.configDirectory,
            workspace: location.workspace)
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
    /// `expected` (from a preview) makes the rollback refuse `headChanged`
    /// when the layer's head or the target moved since that preview. It is
    /// a required argument; it binds only as tightly as the preview it came
    /// from. Like every layer save, the restored document must stay within
    /// the owner's policy ceiling: one that asks where the ceiling denies,
    /// or an invalid `ceiling.toml`, refuses with `PolicyCeilingError`
    /// under the write lock, with nothing written.
    public func rollback(
        layer: PolicyDocumentLayer,
        to revision: Int,
        expected: PolicyRollbackBinding
    ) throws -> PolicyRevision {
        switch layer {
        case .machine:
            guard let directory = machineDirectory else {
                throw PolicyWorkspaceError.missingLayer(.machine)
            }
            return try TypedRuleStore(baseDirectory: directory)
                .rollbackMachine(to: revision, expected: expected, admit: admitWithinCeiling)
        case .repo:
            guard let workspace else {
                throw PolicyWorkspaceError.missingLayer(.repo)
            }
            return try revisionRepoStore(workspace: workspace)
                .rollbackRepo(to: revision, workspace: workspace, expected: expected, admit: admitWithinCeiling)
        }
    }

    /// The ceiling check `mergeIncoming` runs on a save, for rollback.
    private func admitWithinCeiling(_ document: PolicyDocument) throws {
        try loadCeiling()?.requireContained(document)
    }

    /// A layer rollback preview plus the effective rules before and after.
    /// `currentEffective` is nil when a live layer file does not parse;
    /// `restoredEffective` is nil when the other layer's file does not.
    /// `liveHash` is the live layer document's identity (nil: unparseable).
    /// Both effective sets include the owner's policy ceiling (nil when
    /// `ceiling.toml` is invalid). `ceilingRefusal` is why `rollback` would
    /// refuse the restored document against that ceiling, or nil.
    public struct RollbackPreview: Sendable, Equatable {
        public var layer: PolicyDocumentLayer
        public var target: PolicyRevision
        public var head: PolicyRevision
        public var liveParses: Bool
        public var liveHash: String?
        public var risk: PolicyDiffRiskReport
        public var currentEffective: [TypedRule]?
        public var restoredEffective: [TypedRule]?
        public var ceilingRefusal: PolicyCeilingError?

        /// Restoring would change nothing: the target is the head and the
        /// live file already holds that content.
        public var isNoOp: Bool {
            target.hash == head.hash && liveHash == target.hash
        }
    }

    /// Read-only: what `rollback(layer:to:)` would restore and whether its
    /// gate would refuse. Writes nothing; same errors as the rollback.
    public func previewRollback(
        layer: PolicyDocumentLayer,
        to revision: Int,
        builtin: [TypedRule] = []
    ) throws -> RollbackPreview {
        let preview: PolicyRollbackPreview
        switch layer {
        case .machine:
            guard let directory = machineDirectory else {
                throw PolicyWorkspaceError.missingLayer(.machine)
            }
            preview = try TypedRuleStore(baseDirectory: directory).previewMachineRollback(to: revision)
        case .repo:
            guard let workspace else {
                throw PolicyWorkspaceError.missingLayer(.repo)
            }
            preview = try revisionRepoStore(workspace: workspace)
                .previewRepoRollback(to: revision, workspace: workspace)
        }
        let restoredRules = preview.target.document.typedRules(origin: layer == .machine ? .machine : .repo)
        let otherRules: [TypedRule]?
        switch layer {
        case .machine:
            otherRules = try Self.nilWhenUnparseable { try loadRepoDocument().typedRules(origin: .repo) }
        case .repo:
            otherRules = try Self.nilWhenUnparseable { try loadMachineDocument().typedRules(origin: .machine) }
        }
        // An invalid ceiling.toml leaves both effective sets unavailable
        // and refuses the save, as for an unparseable layer.
        var ceiling: PolicyCeiling?
        var ceilingRefusal: PolicyCeilingError?
        do {
            ceiling = try loadCeiling()
        } catch PolicyCeilingError.invalidFile {
            ceilingRefusal = .invalidFile
        }
        if let ceiling {
            do {
                try ceiling.requireContained(preview.target.document)
            } catch let error as PolicyCeilingError {
                ceilingRefusal = error
            }
        }
        let ceilingParses = ceilingRefusal != .invalidFile
        let ceilingRules = ceiling?.typedRules ?? []
        let restoredEffective = ceilingParses == false ? nil : otherRules.map { other in
            layer == .machine
                ? TypedRuleStore.merge(builtin: builtin, machine: restoredRules, repo: other, ceiling: ceilingRules)
                : TypedRuleStore.merge(builtin: builtin, machine: other, repo: restoredRules, ceiling: ceilingRules)
        }
        return RollbackPreview(
            layer: layer,
            target: preview.target,
            head: preview.head,
            liveParses: preview.live != nil,
            liveHash: preview.live.map(PolicyRevisionIdentity.hash),
            risk: preview.risk,
            currentEffective: try Self.nilWhenUnparseable { try loadEffectiveRules(builtin: builtin) },
            restoredEffective: restoredEffective,
            ceilingRefusal: ceilingRefusal
        )
    }

    /// An unparseable policy file (`invalidFile`) is a state the preview
    /// reports, since rollback is its repair path; any other failure
    /// (lock, I/O) propagates instead of reading as "unavailable".
    private static func nilWhenUnparseable<T>(_ load: () throws -> T) throws -> T? {
        do {
            return try load()
        } catch TypedRuleStoreError.invalidFile {
            return nil
        } catch PolicyCeilingError.invalidFile {
            return nil
        }
    }

    /// Returns the saved layer document.
    @discardableResult
    public func upsert(_ rule: PolicyDocumentRule, layer: PolicyDocumentLayer) throws -> PolicyDocument {
        try mergeIncoming(PolicyDocument(rules: [rule]), layer: layer, save: true)
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

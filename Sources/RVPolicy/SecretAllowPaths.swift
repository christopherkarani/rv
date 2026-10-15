import Foundation
import RVDomain

/// Load and merge `secret.allow_paths` from machine config and policy.toml.
///
/// Blessed-union (Option B1): repo-layer literals are untrusted proposals and
/// take effect ONLY when the machine-level `secret.bless_paths` gate names
/// them verbatim. Unblessed repo literals are dropped fail-closed and reported
/// via `EffectiveAllowPaths.droppedRepoLiterals`, the visible signal T7
/// surfaces in show/validate and audit.
///
/// Borrowed patterns, all from OpenShell primary sources:
/// - Proposals never self-apply; each waits for review
///   (https://docs.nvidia.com/openshell/latest/how-it-works/policies/advisor).
/// - A candidate allows nothing beyond its boundary policy
///   (https://docs.nvidia.com/openshell/latest/how-it-works/policies/prover).
/// - Base and effective policy are inspected as separate views
///   (https://docs.nvidia.com/openshell/latest/how-it-works/policies/manage-policies).
public enum SecretAllowPaths {
    /// Blessed-union result: the enforced set plus the repo-layer literals
    /// that requested exemption but were dropped for lack of machine blessing.
    public struct EffectiveAllowPaths: Sendable, Equatable {
        public var effective: SecretAllowPathSet
        public var droppedRepoLiterals: [String]
        /// A policy document existed but failed to load/parse. Its
        /// literals contribute nothing (fail closed), but the failure is
        /// surfaced so a corrupt file never reads as "no exemptions
        /// requested" in exemption accounting.
        public var documentLoadFailed: Bool

        public init(
            effective: SecretAllowPathSet,
            droppedRepoLiterals: [String],
            documentLoadFailed: Bool = false
        ) {
            self.effective = effective
            self.droppedRepoLiterals = droppedRepoLiterals
            self.documentLoadFailed = documentLoadFailed
        }
    }

    /// Order-preserving dedup union of already-authorized literals.
    ///
    /// Enforcement entry points MUST bless repo-layer literals first via
    /// `merge(machine:repo:blessPaths:)` or `loadEffectiveDetailed`; a direct
    /// call with unblessed repo literals (as in document-layer reporting) does
    /// not confer enforcement.
    public static func merge(machine: [String], repo: [String]) -> SecretAllowPathSet {
        SecretAllowPathSet(literals: normalized(machine + repo))
    }

    /// Blessed union: machine literals always take effect; each repo literal
    /// takes effect only when a machine bless entry names it verbatim (after
    /// trimming). A repo literal already covered by the machine list stays
    /// effective via the machine and is not reported as dropped.
    public static func merge(
        machine: [String],
        repo: [String],
        blessPaths: [String]
    ) -> EffectiveAllowPaths {
        let machineLiterals = normalized(machine)
        let blessed = Set(normalized(blessPaths))
        var seen = Set(machineLiterals)
        var effective = machineLiterals
        var dropped: [String] = []
        for literal in normalized(repo) {
            if seen.contains(literal) {
                continue
            }
            if blessed.contains(literal) {
                seen.insert(literal)
                effective.append(literal)
            } else {
                dropped.append(literal)
            }
        }
        return EffectiveAllowPaths(
            effective: SecretAllowPathSet(literals: effective),
            droppedRepoLiterals: dropped
        )
    }

    public static func loadMachineConfig(from file: URL) -> [String] {
        let root = MachineConfigJSON.load(from: file)
        guard let values = root["secret"]?["allow_paths"]?.asArray else {
            return []
        }
        let paths = values.compactMap(\.string)
        guard paths.count == values.count else {
            return []
        }
        return paths
    }

    public static func saveMachineConfig(_ paths: [String], to file: URL) throws {
        try MachineConfigJSON.update(file: file) { root in
            var secret = root["secret"]?.asObject ?? [:]
            secret["allow_paths"] = .array(paths.map(JSONValue.string))
            root["secret"] = .object(secret)
        }
    }

    /// Machine-level bless gate. Missing, mistyped, or partially non-string
    /// content blesses nothing (fail-closed), mirroring `loadMachineConfig`.
    public static func loadBlessPaths(from file: URL) -> [String] {
        let root = MachineConfigJSON.load(from: file)
        guard let values = root["secret"]?["bless_paths"]?.asArray else {
            return []
        }
        let paths = values.compactMap(\.string)
        guard paths.count == values.count else {
            return []
        }
        return paths
    }

    public static func saveBlessPaths(_ paths: [String], to file: URL) throws {
        try MachineConfigJSON.update(file: file) { root in
            var secret = root["secret"]?.asObject ?? [:]
            secret["bless_paths"] = .array(paths.map(JSONValue.string))
            root["secret"] = .object(secret)
        }
    }

    public static func loadEffectiveDetailed(
        home: HomeDirectory?,
        workspace: URL?
    ) -> EffectiveAllowPaths {
        var machine: [String] = []
        var bless: [String] = []
        if let home {
            let configFile = RVPolicyPaths.configDirectory(home: home)
                .appendingPathComponent("config.json", isDirectory: false)
            machine.append(contentsOf: loadMachineConfig(from: configFile))
            bless.append(contentsOf: loadBlessPaths(from: configFile))
        }
        let session = PolicyWorkspace(home: home, workspace: workspace)
        var loadFailed = false
        let machineDoc: [String]
        do {
            machineDoc = try session.loadMachineDocument().allowPaths
        } catch {
            machineDoc = []
            loadFailed = true
        }
        let repoDoc: [String]
        do {
            repoDoc = try session.loadRepoDocument().allowPaths
        } catch {
            repoDoc = []
            loadFailed = true
        }
        var detailed = merge(machine: machine + machineDoc, repo: repoDoc, blessPaths: bless)
        detailed.documentLoadFailed = loadFailed
        return detailed
    }

    public static func loadEffective(home: HomeDirectory?, workspace: URL?) -> SecretAllowPathSet {
        loadEffectiveDetailed(home: home, workspace: workspace).effective
    }

    private static func normalized(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var literals: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.contains(trimmed) == false else { continue }
            seen.insert(trimmed)
            literals.append(trimmed)
        }
        return literals
    }
}

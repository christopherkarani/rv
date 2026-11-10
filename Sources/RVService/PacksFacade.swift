import Foundation
import RVDomain
import RVPacks
import RVPolicy

public struct PacksListRow: Equatable, Sendable {
    public var id: PackID
    public var name: String
    public var category: String
    public var description: String
    public var enabled: Bool
    /// Enforced by the signed organization policy (`gate.requirePacks`)
    /// whatever the user's config says; `enabled` is then true.
    public var requiredByOrganization: Bool = false
    public var safePatternCount: Int
    public var destructivePatternCount: Int
    /// The bundled safe patterns, available to verbose pack presentation.
    public var safePatterns: [NamedPattern]
    /// The bundled destructive rules, available to verbose pack presentation.
    public var destructivePatterns: [DestructiveRule]
}

public struct PacksListSnapshot: Equatable, Sendable {
    public var packs: [PacksListRow]
    public var enabledCount: Int
    public var totalCount: Int

    /// Creates a pack catalog snapshot with catalog-wide counts.
    public init(packs: [PacksListRow], enabledCount: Int, totalCount: Int) {
        self.packs = packs
        self.enabledCount = enabledCount
        self.totalCount = totalCount
    }
}

public struct PacksMutationResult: Equatable, Sendable {
    public var changed: [PackID]
    public var enabledCount: Int
    public var totalCount: Int
}

public enum PacksCommandError: Error, Equatable, Sendable {
    case unknownID(SelectionToken)
    case packNotFound(PackID)
    case configUnwritable
    /// `config.toml` exists but cannot be read: refuse to rewrite it from an
    /// empty config, which would discard the owner's pack choices.
    case configUnreadable
    case criticalPatternUncompilable(RuleID)
}

/// In-process packs list / enable / disable for CLI and tests (temp HOME).
public enum PacksFacade {
    public static func list(
        home: HomeDirectory,
        enabledOnly: Bool = false
    ) throws -> PacksListSnapshot {
        let documents = try PackRegistry.loadAllDocuments()
        // The same resolution the doors use (including the fail-closed
        // answer for an unreadable config).
        let enabled = try effectiveIDs(home: home)
        // What every door enforces: the owner's packs plus the packs the
        // organization requires (`ManagedGate`), so the listing never shows
        // an enforced pack as off.
        let required = Set(ManagedGate.requiredPacks(home: home))
        let on = Set(enabled).union(required.intersection(Set(documents.map(\.id))))
        var rows = documents.map { doc in
            PacksListRow(
                id: doc.id,
                name: doc.name,
                category: doc.category,
                description: doc.description,
                enabled: on.contains(doc.id),
                requiredByOrganization: required.contains(doc.id),
                safePatternCount: doc.safe.count,
                destructivePatternCount: doc.destructive.count,
                safePatterns: doc.safe,
                destructivePatterns: doc.destructive
            )
        }
        rows.sort { $0.id.rawValue < $1.id.rawValue }
        if enabledOnly {
            rows = rows.filter(\.enabled)
        }
        return PacksListSnapshot(
            packs: rows,
            enabledCount: on.count,
            totalCount: documents.count
        )
    }

    public static func info(home: HomeDirectory, id: PackID) throws -> PacksListRow {
        let snapshot = try list(home: home)
        guard let row = snapshot.packs.first(where: { $0.id == id }) else {
            throw PacksCommandError.packNotFound(id)
        }
        return row
    }

    /// Verb-argument / XPC boundary: raw operator strings become tokens here.
    public static func enable(home: HomeDirectory, ids: [String]) throws -> PacksMutationResult {
        try mutate(home: home, ids: ids, enabling: true)
    }

    public static func disable(home: HomeDirectory, ids: [String]) throws -> PacksMutationResult {
        try mutate(home: home, ids: ids, enabling: false)
    }

    /// Enables the packs, categories, and presets named by `selections`.
    public static func enable(home: HomeDirectory, selections: [SelectionToken]) throws -> PacksMutationResult {
        try mutate(home: home, selections: selections, enabling: true)
    }

    /// Disables the packs, categories, and presets named by `selections`.
    public static func disable(home: HomeDirectory, selections: [SelectionToken]) throws -> PacksMutationResult {
        try mutate(home: home, selections: selections, enabling: false)
    }

    public static func effectiveIDs(home: HomeDirectory) throws -> [PackID] {
        // Only a definitely-absent file means day-one; a stat failure such as
        // EACCES on a parent directory takes the fail-closed branch below.
        if PacksConfigStore.isAbsent(home: home) {
            return dayOnePackIDs
        }
        let index = try PackRegistry.loadIndex()
        let config: PacksConfig
        do {
            config = try PacksConfigStore.load(home: home)
        } catch {
            // The file exists but cannot be read (permissions, invalid
            // UTF-8). Falling back to the day-one defaults would silently
            // drop every pack the owner enabled, at every door, without an
            // owner action. Fail closed: every bundled pack, until the owner
            // repairs the file (`rv doctor` reports the packs as broken, and
            // `rv packs enable/disable` refuse to overwrite it).
            return PackSet.order(Set(index.packIDs), index: index)
        }
        return try PackSet.effectiveOrdered(
            enabled: selectionTokens(config.enabled, index: index),
            disabled: selectionTokens(config.disabled, index: index),
            index: index
        )
    }

    public static func makeCatalog(home: HomeDirectory) throws -> PackCatalog {
        let index = try PackRegistry.loadIndex()
        let enabled = Set(try effectiveIDs(home: home))
        return PackCatalog.make(enabled: enabled, index: index)
    }

    private static func mutate(home: HomeDirectory, ids: [String], enabling: Bool) throws -> PacksMutationResult {
        let index = try PackRegistry.loadIndex()
        return try mutate(
            home: home,
            selections: selectionTokens(ids, index: index),
            enabling: enabling,
            index: index
        )
    }

    private static func mutate(
        home: HomeDirectory,
        selections: [SelectionToken],
        enabling: Bool
    ) throws -> PacksMutationResult {
        let index = try PackRegistry.loadIndex()
        return try mutate(home: home, selections: selections, enabling: enabling, index: index)
    }

    private static func mutate(
        home: HomeDirectory,
        selections: [SelectionToken],
        enabling: Bool,
        index: PackIndex
    ) throws -> PacksMutationResult {
        let expansion: Set<PackID>
        do {
            expansion = try PackSet.expand(selections, index: index, rejectUnknown: true)
        } catch PackSetError.unknownID(let token) {
            throw PacksCommandError.unknownID(token)
        }

        var config: PacksConfig
        do {
            config = try PacksConfigStore.load(home: home)
        } catch {
            throw PacksCommandError.configUnreadable
        }
        let before = Set(
            try PackSet.effectiveOrdered(
                enabled: selectionTokens(config.enabled, index: index),
                disabled: selectionTokens(config.disabled, index: index),
                index: index
            )
        )

        if enabling {
            // PLAN #16 / phase-2: critical/high ICU miss → typed error, no config write.
            try PackEnableCompileGate.assertBlockingPatternsCompile(packIDs: expansion)

            // Persist operator tokens (pack / category / preset); expand at read time.
            config.enabled = mergeUnique(config.enabled, selections.map(\.rawValue))
            config.disabled = config.disabled.filter { token in
                let tokenExpansion =
                    (try? PackSet.expand(selectionTokens([token], index: index), index: index))
                    ?? []
                return tokenExpansion.isDisjoint(with: expansion)
            }
        } else {
            // Drop exact enabled tokens that the operator named; persist disables after expand.
            let named = Set(selections.map(\.rawValue))
            config.enabled = config.enabled.filter { !named.contains($0) }
            config.disabled = mergeUnique(config.disabled, selections.map(\.rawValue))
        }

        do {
            try PacksConfigStore.save(config, home: home)
        } catch {
            throw PacksCommandError.configUnwritable
        }

        let after = try PackSet.effectiveOrdered(
            enabled: selectionTokens(config.enabled, index: index),
            disabled: selectionTokens(config.disabled, index: index),
            index: index
        )
        let afterSet = Set(after)
        let changed: [PackID]
        if enabling {
            changed = afterSet.subtracting(before).sorted { $0.rawValue < $1.rawValue }
        } else {
            changed = before.subtracting(afterSet).sorted { $0.rawValue < $1.rawValue }
        }
        return PacksMutationResult(
            changed: changed,
            enabledCount: after.count,
            totalCount: index.packCount
        )
    }

    private static func selectionTokens(_ raws: [String], index: PackIndex) -> [SelectionToken] {
        raws.flatMap { SelectionToken.tokens(from: $0, index: index) }
    }

    private static func mergeUnique(_ base: [String], _ extra: [String]) -> [String] {
        var seen = Set(base)
        var out = base
        for item in extra.sorted() where !seen.contains(item) {
            out.append(item)
            seen.insert(item)
        }
        return out
    }
}

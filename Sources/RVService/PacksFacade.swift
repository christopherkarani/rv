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
    public var safePatternCount: Int
    public var destructivePatternCount: Int
}

public struct PacksListSnapshot: Equatable, Sendable {
    public var packs: [PacksListRow]
    public var enabledCount: Int
    public var totalCount: Int
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
    case criticalPatternUncompilable(RuleID)
}

/// In-process packs list / enable / disable for CLI and tests (temp HOME).
public enum PacksFacade {
    public static func list(
        home: HomeDirectory,
        enabledOnly: Bool = false
    ) throws -> PacksListSnapshot {
        let index = try PackRegistry.loadIndex()
        let documents = try PackRegistry.loadAllDocuments()
        let config = (try? PacksConfigStore.load(home: home)) ?? .empty
        let enabled = try PackSet.effectiveOrdered(
            enabled: selectionTokens(config.enabled, index: index),
            disabled: selectionTokens(config.disabled, index: index),
            index: index
        )
        let on = Set(enabled)
        var rows = documents.map { doc in
            PacksListRow(
                id: doc.id,
                name: doc.name,
                category: doc.category,
                description: doc.description,
                enabled: on.contains(doc.id),
                safePatternCount: doc.safe.count,
                destructivePatternCount: doc.destructive.count
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

    /// Verb-argument / XPC boundary: raw selection strings become tokens here and
    /// nowhere else downstream of the persisted config.
    public static func enable(home: HomeDirectory, ids: [String]) throws -> PacksMutationResult {
        try mutate(home: home, ids: ids, enabling: true)
    }

    public static func disable(home: HomeDirectory, ids: [String]) throws -> PacksMutationResult {
        try mutate(home: home, ids: ids, enabling: false)
    }

    public static func enable(home: HomeDirectory, tokens: [SelectionToken]) throws -> PacksMutationResult {
        try mutate(home: home, tokens: tokens, enabling: true)
    }

    public static func disable(home: HomeDirectory, tokens: [SelectionToken]) throws -> PacksMutationResult {
        try mutate(home: home, tokens: tokens, enabling: false)
    }

    public static func effectiveIDs(home: HomeDirectory) throws -> [PackID] {
        let configURL = PacksConfigStore.configURL(home: home)
        if FileManager.default.fileExists(atPath: configURL.path) == false {
            return dayOnePackIDs
        }
        let index = try PackRegistry.loadIndex()
        let config = (try? PacksConfigStore.load(home: home)) ?? .empty
        return try PackSet.effectiveOrdered(
            enabled: selectionTokens(config.enabled, index: index),
            disabled: selectionTokens(config.disabled, index: index),
            index: index
        )
    }

    public static func makeCatalog(home: HomeDirectory) throws -> PackCatalog {
        let index = try PackRegistry.loadIndex()
        let enabled = Set(try effectiveIDs(home: home))
        return try PackCatalog.bundlingAll(enabled: enabled, index: index)
    }

    private static func mutate(home: HomeDirectory, ids: [String], enabling: Bool) throws -> PacksMutationResult {
        let index = try PackRegistry.loadIndex()
        return try mutate(
            home: home,
            tokens: selectionTokens(ids, index: index),
            enabling: enabling,
            index: index
        )
    }

    private static func mutate(
        home: HomeDirectory,
        tokens: [SelectionToken],
        enabling: Bool
    ) throws -> PacksMutationResult {
        let index = try PackRegistry.loadIndex()
        return try mutate(home: home, tokens: tokens, enabling: enabling, index: index)
    }

    private static func mutate(
        home: HomeDirectory,
        tokens: [SelectionToken],
        enabling: Bool,
        index: PackIndex
    ) throws -> PacksMutationResult {
        let expansion: Set<PackID>
        do {
            expansion = try PackSet.expand(tokens, index: index, rejectUnknown: true)
        } catch PackSetError.unknownID(let token) {
            throw PacksCommandError.unknownID(token)
        }

        var config = (try? PacksConfigStore.load(home: home)) ?? .empty
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
            config.enabled = mergeUnique(config.enabled, tokens.map(\.rawValue))
            config.disabled = config.disabled.filter { token in
                let tokenExpansion =
                    (try? PackSet.expand(selectionTokens([token], index: index), index: index))
                    ?? []
                return tokenExpansion.isDisjoint(with: expansion)
            }
        } else {
            // Drop exact enabled tokens that the operator named; persist disables after expand.
            let named = Set(tokens.map(\.rawValue))
            config.enabled = config.enabled.filter { !named.contains($0) }
            config.disabled = mergeUnique(config.disabled, tokens.map(\.rawValue))
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
        raws.flatMap { SelectionToken.parse($0, index: index) }
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

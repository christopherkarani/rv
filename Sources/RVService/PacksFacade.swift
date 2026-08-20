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
    public var changed: [String]
    public var enabledCount: Int
    public var totalCount: Int
}

public enum PacksCommandError: Error, Equatable, Sendable {
    case unknownID(String)
    case packNotFound(String)
    case configUnwritable
    case criticalPatternUncompilable(String)
}

/// In-process packs list / enable / disable for CLI and tests (temp HOME).
public enum PacksFacade {
    public static func list(
        home: String,
        enabledOnly: Bool = false
    ) throws -> PacksListSnapshot {
        let index = try PackRegistry.loadIndex()
        let documents = try PackRegistry.loadAllDocuments()
        let config = (try? PacksConfigStore.load(home: home)) ?? .empty
        let enabled = try PackSet.effectiveOrdered(
            enabled: config.enabled,
            disabled: config.disabled,
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

    public static func info(home: String, id: String) throws -> PacksListRow {
        let snapshot = try list(home: home)
        guard let row = snapshot.packs.first(where: { $0.id.rawValue == id }) else {
            throw PacksCommandError.packNotFound(id)
        }
        return row
    }

    public static func enable(home: String, ids: [String]) throws -> PacksMutationResult {
        try mutate(home: home, ids: ids, enabling: true)
    }

    public static func disable(home: String, ids: [String]) throws -> PacksMutationResult {
        try mutate(home: home, ids: ids, enabling: false)
    }

    public static func effectiveIDs(home: String) throws -> [PackID] {
        let index = try PackRegistry.loadIndex()
        if home.isEmpty {
            return try PackSet.effectiveOrdered(enabled: [], disabled: [], index: index)
        }
        let config = (try? PacksConfigStore.load(home: home)) ?? .empty
        return try PackSet.effectiveOrdered(
            enabled: config.enabled,
            disabled: config.disabled,
            index: index
        )
    }

    public static func makeCatalog(home: String) throws -> PackCatalog {
        let index = try PackRegistry.loadIndex()
        let enabled = Set(try effectiveIDs(home: home))
        return PackCatalog.bundlingAll(enabled: enabled, index: index)
    }

    private static func mutate(home: String, ids: [String], enabling: Bool) throws -> PacksMutationResult {
        guard !home.isEmpty else { throw PacksCommandError.configUnwritable }
        let index = try PackRegistry.loadIndex()
        let expansion: Set<String>
        do {
            expansion = try PackSet.expand(ids, index: index, rejectUnknown: true)
        } catch PackSetError.unknownID(let token) {
            throw PacksCommandError.unknownID(token)
        }

        var config = (try? PacksConfigStore.load(home: home)) ?? .empty
        let before = Set(
            try PackSet.effectiveOrdered(
                enabled: config.enabled,
                disabled: config.disabled,
                index: index
            ).map(\.rawValue)
        )

        if enabling {
            // PLAN #16 / phase-2: critical/high ICU miss → typed error, no config write.
            try PackEnableCompileGate.assertBlockingPatternsCompile(packIDs: expansion)

            // Persist operator tokens (pack / category / preset); expand at read time.
            config.enabled = mergeUnique(config.enabled, ids)
            config.disabled = config.disabled.filter { token in
                let tokenExpansion =
                    (try? PackSet.expand([token], index: index, rejectUnknown: false)) ?? []
                return tokenExpansion.isDisjoint(with: expansion)
            }
        } else {
            // Drop exact enabled tokens that the operator named; persist disables after expand.
            let named = Set(ids)
            config.enabled = config.enabled.filter { !named.contains($0) }
            config.disabled = mergeUnique(config.disabled, ids)
        }

        do {
            try PacksConfigStore.save(config, home: home)
        } catch {
            throw PacksCommandError.configUnwritable
        }

        let after = try PackSet.effectiveOrdered(
            enabled: config.enabled,
            disabled: config.disabled,
            index: index
        )
        let afterSet = Set(after.map(\.rawValue))
        let changed: [String]
        if enabling {
            changed = afterSet.subtracting(before).sorted()
        } else {
            changed = before.subtracting(afterSet).sorted()
        }
        return PacksMutationResult(
            changed: changed,
            enabledCount: after.count,
            totalCount: index.packCount
        )
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

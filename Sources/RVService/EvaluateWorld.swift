import Foundation
import RVDomain
import RVPacks
import RVPolicy

/// The one assembly site for an evaluation world: snapshot fallback chain,
/// enabled-ID rule, and the door around the resulting session.
package enum EvaluationWorld {
    /// Full catalog first; day-one when the index is missing; none when both fail.
    package static func resolveSnapshots(_ provided: [PackSnapshot]?) -> [PackSnapshot] {
        provided ?? ((try? PackRegistry.loadAll()) ?? ((try? PackRegistry.loadDayOne()) ?? []))
    }

    /// Catalog/effective enabled IDs, plus day-one so a catalog disable cannot
    /// uncompile required core rules or change what a session compiles.
    package static func enabledIDs(
        catalog: PackCatalog?,
        home: String?
    ) -> [PackID] {
        let base: [PackID]
        if let catalog {
            base = catalog.records.isEmpty
                ? dayOnePackIDs
                : catalog.records.filter(\.enabled).map(\.id)
        } else {
            base = EnabledPacks.resolve(home: home ?? EnabledPacks.processHome())
        }
        var ids = base
        for id in dayOnePackIDs where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// Eager session for callers that need readiness at build time (rvd).
    package static func makeSession(
        home: String?,
        snapshots: [PackSnapshot]?,
        catalog: PackCatalog?
    ) -> EvaluateSession {
        EvaluateSession(
            snapshots: resolveSnapshots(snapshots),
            enabledPacks: enabledIDs(catalog: catalog, home: home)
        )
    }

    /// The assembly door; its session builds on first evaluate, never here.
    package static func assemble(
        home: String?,
        snapshots: [PackSnapshot]?,
        catalog: PackCatalog?
    ) -> GatedEvaluate {
        GatedEvaluate(lazySession: {
            makeSession(home: home, snapshots: snapshots, catalog: catalog)
        })
    }
}

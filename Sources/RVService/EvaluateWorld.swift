import Foundation
import RVDomain
import RVPacks
import RVPolicy

/// Pack IDs this evaluate walks. Config as written. Empty included. May omit day-one.
public struct WalkedPackIDs: Sendable, Equatable {
    public let ids: [PackID]

    public init(ids: [PackID]) {
        self.ids = ids
    }
}

/// Pack IDs compiled into an Evaluate session. Always includes day-one when built from coverage.
public struct CompiledPackIDs: Sendable, Equatable {
    public let ids: [PackID]

    public init(ids: [PackID]) {
        self.ids = ids
    }
}

/// Walk set plus the compile set derived from it. Compile = walk ∪ day-one.
public struct PackCoverage: Sendable, Equatable {
    public let walked: WalkedPackIDs
    public let compiled: CompiledPackIDs

    /// Walked order preserved; missing day-one IDs appended. The only walk→compile union.
    public static func unioningDayOne(_ walked: WalkedPackIDs) -> PackCoverage {
        var compiled = walked.ids
        for id in dayOnePackIDs where !compiled.contains(id) {
            compiled.append(id)
        }
        return PackCoverage(walked: walked, compiled: CompiledPackIDs(ids: compiled))
    }
}

/// The one assembly site for an evaluation world: snapshot fallback chain,
/// enabled-ID rule, and the door around the resulting session.
package enum EvaluationWorld {
    /// Full catalog first; day-one when the index is missing; none when both fail.
    package static func resolveSnapshots(_ provided: [PackSnapshot]?) -> [PackSnapshot] {
        provided ?? ((try? PackRegistry.loadAll()) ?? ((try? PackRegistry.loadDayOne()) ?? []))
    }

    /// Walk from catalog flags or config; compile = walk ∪ day-one.
    /// Nil home is day-one walk, not process HOME.
    package static func coverage(
        catalog: PackCatalog?,
        home: HomeDirectory?
    ) -> PackCoverage {
        let walked: WalkedPackIDs
        if let catalog {
            let ids = catalog.records.isEmpty
                ? dayOnePackIDs
                : catalog.records.filter(\.enabled).map(\.id)
            walked = WalkedPackIDs(ids: ids)
        } else {
            walked = EnabledPacks.resolve(home: home)
        }
        return PackCoverage.unioningDayOne(walked)
    }

    /// Eager session for callers that need readiness at build time (rvd).
    package static func makeSession(
        coverage: PackCoverage,
        snapshots: [PackSnapshot]?
    ) -> EvaluateSession {
        EvaluateSession(
            snapshots: resolveSnapshots(snapshots),
            compiledPacks: coverage.compiled
        )
    }

    /// The assembly door; its session builds on first use, never here.
    package static func assemble(
        home: HomeDirectory?,
        snapshots: [PackSnapshot]?,
        catalog: PackCatalog?
    ) -> GatedEvaluate {
        GatedEvaluate(lazySession: {
            makeSession(
                coverage: coverage(catalog: catalog, home: home),
                snapshots: snapshots
            )
        })
    }
}
